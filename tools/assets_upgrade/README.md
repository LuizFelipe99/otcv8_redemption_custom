# Assets upgrade

Carries the custom items, outfits, effects and sprite sheets from the current client assets into a newer official assets version.

Requirements: `python -m pip install protobuf grpcio-tools`

```
python tools/assets_upgrade/merge_custom_assets.py ^
  --old-official <official 15.11 assets folder> ^
  --custom data/things/1511 ^
  --new-official <official 15.25 assets folder> ^
  --output data/things/1525
```

- Official assets: https://github.com/dudantas/tibia-client (tags `15.11.c9d1cf` and `15.25.0a00a0`, folder `assets`).
- Custom sprite ids that collide with the new official sprites are moved after the last official sprite, and the custom appearances are updated to match.
- After merging, regenerate the HD sprites: `python tools/hd_sprites/convert_hd_sprites.py --source data/things/1525 --scale 2`.

## Forge classification of an item

```
python tools/assets_upgrade/set_upgrade_classification.py ^
  --assets data/things/1525 ^
  --item 60556 ^
  --classification 4 ^
  --server-appearances <server folder>/data/items/appearances.dat
```

- Sets the upgrade classification (forge class) of an item in the client appearances and optionally copies the file to the server.
- Client and server must use the same appearances file, otherwise the tier byte desyncs the protocol.
- After changing it, regenerate the HD sprites so the HD folder gets the new appearances.
