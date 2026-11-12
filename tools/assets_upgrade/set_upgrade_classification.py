import argparse
import shutil
from pathlib import Path

from merge_custom_assets import catalog_entries_of_type, load_protobuf_module, read_catalog


def find_object(appearances, item_id):
    for appearance in appearances.object:
        if appearance.id == item_id:
            return appearance
    return None


def set_upgrade_classification(assets_folder, item_id, classification, server_appearances):
    protobuf_module = load_protobuf_module()
    catalog = read_catalog(assets_folder)
    appearances_file = assets_folder / catalog_entries_of_type(catalog, "appearances")[0]["file"]
    appearances = protobuf_module.Appearances()
    appearances.ParseFromString(appearances_file.read_bytes())

    item_appearance = find_object(appearances, item_id)
    if item_appearance is None:
        raise SystemExit(f"item {item_id} not found in {appearances_file.name}")

    if item_appearance.flags.cumulative:
        print(f"warning: item {item_id} is stackable, tiers do not work on stackable items")

    item_appearance.flags.upgradeclassification.upgrade_classification = classification
    appearances_file.write_bytes(appearances.SerializeToString())
    print(f"item {item_id} now has upgrade classification {classification} in {appearances_file.name}")

    if server_appearances:
        shutil.copy2(appearances_file, server_appearances)
        print(f"copied to {server_appearances}")


def parse_arguments():
    parser = argparse.ArgumentParser(description="Set the upgrade classification (forge class) of an item in the client assets.")
    parser.add_argument("--assets", required=True, type=Path, help="client assets folder, e.g. data/things/1525")
    parser.add_argument("--item", required=True, type=int, help="item id")
    parser.add_argument("--classification", required=True, type=int, choices=[0, 1, 2, 3, 4])
    parser.add_argument("--server-appearances", type=Path, help="optional path of the server data/items/appearances.dat to overwrite")
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_arguments()
    set_upgrade_classification(arguments.assets, arguments.item, arguments.classification, arguments.server_appearances)
