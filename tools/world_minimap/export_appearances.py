import struct
import sys
import appearances_pb2

CATEGORY_COMMON = 0
CATEGORY_GROUND = 1
CATEGORY_CLIP = 2
CATEGORY_BOTTOM = 3
CATEGORY_TOP = 4
FLAG_NOT_WALKABLE = 1
FLAG_NOT_PATHABLE = 2


def resolve_category(flags):
    if flags.HasField("bank"):
        return CATEGORY_GROUND
    if flags.clip:
        return CATEGORY_CLIP
    if flags.bottom:
        return CATEGORY_BOTTOM
    if flags.top:
        return CATEGORY_TOP
    return CATEGORY_COMMON


def resolve_movement_flags(flags):
    movement_flags = 0
    if flags.unpass:
        movement_flags |= FLAG_NOT_WALKABLE
    if flags.avoid:
        movement_flags |= FLAG_NOT_PATHABLE
    return movement_flags


def export_item_table(appearances_path, output_path):
    appearances = appearances_pb2.Appearances()
    with open(appearances_path, "rb") as appearances_file:
        appearances.ParseFromString(appearances_file.read())

    with open(output_path, "wb") as output_file:
        for item in appearances.object:
            flags = item.flags
            minimap_color = flags.automap.color if flags.HasField("automap") else 0
            ground_speed = flags.bank.waypoints if flags.HasField("bank") else 0
            output_file.write(struct.pack("<HBBBH", item.id, resolve_category(flags), resolve_movement_flags(flags), minimap_color, ground_speed))
    print(f"exported {len(appearances.object)} items")


export_item_table(sys.argv[1], sys.argv[2])
