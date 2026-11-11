import argparse
import hashlib
import importlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CLIENT_ROOT = Path(__file__).resolve().parents[2]
PROTO_DIRECTORY = CLIENT_ROOT / "src" / "protobuf"
APPEARANCE_CATEGORIES = ["object", "outfit", "effect", "missile"]
CATALOG_FILE_NAME = "catalog-content.json"
ASSETS_CHECKSUM_FILE_NAME = "assets.json.sha256"


def load_protobuf_module():
    generated_directory = Path(tempfile.mkdtemp(prefix="appearances_pb2_"))
    subprocess.run(
        [sys.executable, "-m", "grpc_tools.protoc", f"-I{PROTO_DIRECTORY}", f"--python_out={generated_directory}", str(PROTO_DIRECTORY / "appearances.proto")],
        check=True,
    )
    sys.path.insert(0, str(generated_directory))
    return importlib.import_module("appearances_pb2")


def read_catalog(folder):
    return json.loads((folder / CATALOG_FILE_NAME).read_text())


def catalog_entries_of_type(catalog, entry_type):
    return [entry for entry in catalog if entry["type"] == entry_type]


def read_appearances(protobuf_module, folder, catalog):
    appearances_entry = catalog_entries_of_type(catalog, "appearances")[0]
    appearances = protobuf_module.Appearances()
    appearances.ParseFromString((folder / appearances_entry["file"]).read_bytes())
    return appearances


def highest_sprite_id(catalog):
    return max(entry["lastspriteid"] for entry in catalog_entries_of_type(catalog, "sprite"))


def find_custom_sheets(custom_catalog, old_official_catalog):
    official_files = {entry["file"] for entry in catalog_entries_of_type(old_official_catalog, "sprite")}
    return [entry for entry in catalog_entries_of_type(custom_catalog, "sprite") if entry["file"] not in official_files]


def split_custom_sheets(custom_sheets, old_official_highest_sprite):
    replaced_official_sheets = [entry for entry in custom_sheets if entry["lastspriteid"] <= old_official_highest_sprite]
    appended_sheets = [entry for entry in custom_sheets if entry["firstspriteid"] > old_official_highest_sprite]
    straddling_sheets = [entry for entry in custom_sheets if entry not in replaced_official_sheets and entry not in appended_sheets]
    if straddling_sheets:
        raise SystemExit(f"custom sheets crossing the official sprite range are not supported: {[entry['file'] for entry in straddling_sheets]}")
    return replaced_official_sheets, appended_sheets


def find_custom_appearances(custom_appearances, old_official_appearances, category):
    official_ids = {entry.id for entry in getattr(old_official_appearances, category)}
    return [entry for entry in getattr(custom_appearances, category) if entry.id not in official_ids]


def resolve_custom_ids(custom_entries, new_official_ids, category):
    if category != "outfit":
        return {entry.id: entry.id for entry in custom_entries}

    custom_ids = {entry.id for entry in custom_entries}
    next_free_id = max(new_official_ids) + 1
    resolved_ids = {}
    for entry in sorted(custom_entries, key=lambda custom_entry: custom_entry.id):
        if entry.id not in new_official_ids:
            resolved_ids[entry.id] = entry.id
            continue
        while next_free_id in new_official_ids or next_free_id in custom_ids:
            next_free_id += 1
        resolved_ids[entry.id] = next_free_id
        print(f"{category} {entry.id} collides with a new official {category}, moved to {next_free_id}")
        next_free_id += 1
    return resolved_ids


def remap_sprite_ids(appearance, old_official_highest_sprite, sprite_offset):
    for frame_group in appearance.frame_group:
        sprite_ids = frame_group.sprite_info.sprite_id
        for index, sprite_id in enumerate(sprite_ids):
            if sprite_id > old_official_highest_sprite:
                sprite_ids[index] = sprite_id + sprite_offset


def merge_appearances(protobuf_module, new_official_appearances, custom_appearances, old_official_appearances, old_official_highest_sprite, sprite_offset):
    merged = protobuf_module.Appearances()
    merged.CopyFrom(new_official_appearances)
    for category in APPEARANCE_CATEGORIES:
        combined = {entry.id: entry for entry in getattr(new_official_appearances, category)}
        custom_entries = find_custom_appearances(custom_appearances, old_official_appearances, category)
        resolved_ids = resolve_custom_ids(custom_entries, set(combined), category)
        for custom_entry in custom_entries:
            remapped_entry = protobuf_module.Appearance()
            remapped_entry.CopyFrom(custom_entry)
            remapped_entry.id = resolved_ids[custom_entry.id]
            remap_sprite_ids(remapped_entry, old_official_highest_sprite, sprite_offset)
            combined[remapped_entry.id] = remapped_entry
        merged.ClearField(category)
        target = getattr(merged, category)
        for entry_id in sorted(combined):
            target.add().CopyFrom(combined[entry_id])
        print(f"{category}: {len(custom_entries)} custom entries kept")
    return merged


def build_sprite_entries(new_official_catalog, replaced_official_sheets, appended_sheets, sprite_offset):
    replaced_ranges = {(entry["firstspriteid"], entry["lastspriteid"]) for entry in replaced_official_sheets}
    sprite_entries = [entry for entry in catalog_entries_of_type(new_official_catalog, "sprite") if (entry["firstspriteid"], entry["lastspriteid"]) not in replaced_ranges]
    sprite_entries += replaced_official_sheets
    for sheet in appended_sheets:
        remapped_sheet = dict(sheet)
        remapped_sheet["firstspriteid"] = sheet["firstspriteid"] + sprite_offset
        remapped_sheet["lastspriteid"] = sheet["lastspriteid"] + sprite_offset
        sprite_entries.append(remapped_sheet)
    return sorted(sprite_entries, key=lambda entry: entry["firstspriteid"])


def copy_folder_files(source_folder, output_folder, file_names):
    missing_files = []
    for file_name in file_names:
        source_file = source_folder / file_name
        if not source_file.exists():
            missing_files.append(file_name)
            continue
        shutil.copy2(source_file, output_folder / file_name)
    return missing_files


def copy_assets_checksum(new_official_folder, custom_folder, output_folder):
    candidate_files = [
        new_official_folder / ASSETS_CHECKSUM_FILE_NAME,
        new_official_folder.parent / ASSETS_CHECKSUM_FILE_NAME,
        custom_folder / ASSETS_CHECKSUM_FILE_NAME,
    ]
    for candidate_file in candidate_files:
        if candidate_file.exists():
            shutil.copy2(candidate_file, output_folder / ASSETS_CHECKSUM_FILE_NAME)
            return True
    return False


def write_merged_folder(output_folder, new_official_folder, custom_folder, new_official_catalog, sprite_entries, appended_or_replaced_sheets, merged_appearances_bytes):
    output_folder.mkdir(parents=True, exist_ok=True)
    appearances_file_name = f"appearances-{hashlib.sha256(merged_appearances_bytes).hexdigest()}.dat"
    (output_folder / appearances_file_name).write_bytes(merged_appearances_bytes)

    custom_sheet_files = {entry["file"] for entry in appended_or_replaced_sheets}
    official_files = [entry["file"] for entry in new_official_catalog if entry["type"] not in ("appearances",) and entry.get("file") and entry["file"] not in custom_sheet_files]
    missing_official = copy_folder_files(new_official_folder, output_folder, official_files)
    missing_custom = copy_folder_files(custom_folder, output_folder, sorted(custom_sheet_files))

    other_entries = [entry for entry in new_official_catalog if entry["type"] not in ("sprite", "appearances")]
    merged_catalog = [{"type": "appearances", "file": appearances_file_name}] + other_entries + sprite_entries
    (output_folder / CATALOG_FILE_NAME).write_text(json.dumps(merged_catalog, indent=2))
    if not copy_assets_checksum(new_official_folder, custom_folder, output_folder):
        print(f"warning: {ASSETS_CHECKSUM_FILE_NAME} not found, the client will not recognize the folder as installed")
    return missing_official, missing_custom


def merge_custom_assets(old_official_folder, custom_folder, new_official_folder, output_folder):
    protobuf_module = load_protobuf_module()
    old_official_catalog = read_catalog(old_official_folder)
    custom_catalog = read_catalog(custom_folder)
    new_official_catalog = read_catalog(new_official_folder)

    old_official_highest_sprite = highest_sprite_id(old_official_catalog)
    new_official_highest_sprite = highest_sprite_id(new_official_catalog)
    custom_sheets = find_custom_sheets(custom_catalog, old_official_catalog)
    replaced_official_sheets, appended_sheets = split_custom_sheets(custom_sheets, old_official_highest_sprite)
    lowest_custom_sprite = min((entry["firstspriteid"] for entry in appended_sheets), default=new_official_highest_sprite + 1)
    sprite_offset = max(0, new_official_highest_sprite + 1 - lowest_custom_sprite)
    print(f"custom sheets: {len(appended_sheets)} new, {len(replaced_official_sheets)} replacing official ones, sprite offset {sprite_offset}")

    merged_appearances = merge_appearances(
        protobuf_module,
        read_appearances(protobuf_module, new_official_folder, new_official_catalog),
        read_appearances(protobuf_module, custom_folder, custom_catalog),
        read_appearances(protobuf_module, old_official_folder, old_official_catalog),
        old_official_highest_sprite,
        sprite_offset,
    )
    sprite_entries = build_sprite_entries(new_official_catalog, replaced_official_sheets, appended_sheets, sprite_offset)
    missing_official, missing_custom = write_merged_folder(
        output_folder, new_official_folder, custom_folder, new_official_catalog, sprite_entries, replaced_official_sheets + appended_sheets, merged_appearances.SerializeToString()
    )
    if missing_official or missing_custom:
        print(f"warning: {len(missing_official)} official and {len(missing_custom)} custom files were missing and not copied")
    print(f"merged assets written to {output_folder}")


def parse_arguments():
    parser = argparse.ArgumentParser(description="Carry custom items and sprites from an old client assets folder into a new official version")
    parser.add_argument("--old-official", required=True, type=Path, help="unmodified official assets of the old version, e.g. 15.11")
    parser.add_argument("--custom", required=True, type=Path, help="your current customized assets folder, e.g. data/things/1511")
    parser.add_argument("--new-official", required=True, type=Path, help="unmodified official assets of the new version, e.g. 15.25")
    parser.add_argument("--output", required=True, type=Path, help="destination folder, e.g. data/things/1525")
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_arguments()
    merge_custom_assets(arguments.old_official, arguments.custom, arguments.new_official, arguments.output)
