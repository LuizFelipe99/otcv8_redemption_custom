# HD sprites (xBRZ)

Generates an HD copy of the protobuf sprite sheets (`data/things/<version>`) using the
[xBRZ](https://sourceforge.net/projects/xbrz/) pixel-art scaler. The client loads the HD copy
when **Options > Graphics > HD Mode** is enabled and `data/things/<version>_hd` exists.

## Requirements

- Python 3.8+ (no extra packages)
- `xbrz_raw.exe` (already built, Windows x64). To rebuild it:
  - Windows (MinGW): `g++ -std=c++17 -O2 -static -o xbrz_raw.exe xbrz_raw.cpp xbrz/xbrz.cpp -DNDEBUG`
  - Linux: `g++ -std=c++17 -O2 -o xbrz_raw xbrz_raw.cpp xbrz/xbrz.cpp -DNDEBUG`

## Usage

From the client root:

```
python tools/hd_sprites/convert_hd_sprites.py --source data/things/1511 --scale 2
```

- Output: `data/things/1511_hd` (sprite sheets upscaled, other asset files copied, and a
  `spritescale` entry added to `catalog-content.json`).
- Running it again only converts sheets that changed, so after adding custom sprites just run it again.
- `--workers N` sets how many CPU cores are used (default: all but one).

## License

`xbrz/` is xBRZ by Zenju, licensed under GPL-3.0 (see `xbrz/License.txt`). It is only used by this
offline converter; it is not linked into the client.
