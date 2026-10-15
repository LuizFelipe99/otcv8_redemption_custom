import argparse
import json
import lzma
import multiprocessing
import os
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

BASE_SHEET_SIZE = 384
BYTES_PER_PIXEL = 4
EDGE_PADDING = 3
CIP_HEADER_SIZE = 32
CIP_MARKER = bytes([0x70, 0x0A, 0xFA, 0x80, 0x24])
BITMAP_HEADER_SIZE = 54
TRANSPARENT_PIXEL = bytes(4)
SPRITE_SCALE_CATALOG_TYPE = "spritescale"

LAYOUT_SIZES = {
    0: (32, 32), 1: (32, 64), 2: (64, 32), 3: (64, 64),
    4: (32, 96), 5: (32, 128), 6: (32, 192), 7: (32, 384),
    8: (64, 96), 9: (64, 128), 10: (64, 192), 11: (64, 384),
    12: (96, 32), 13: (96, 64), 14: (96, 96), 15: (96, 128), 16: (96, 192), 17: (96, 384),
    18: (128, 32), 19: (128, 64), 20: (128, 96), 21: (128, 128), 22: (128, 192), 23: (128, 384),
    24: (192, 32), 25: (192, 64), 26: (192, 96), 27: (192, 128), 28: (192, 192), 29: (192, 384),
    30: (384, 32), 31: (384, 64), 32: (384, 96), 33: (384, 128), 34: (384, 192), 35: (384, 384),
}

scalerProcess = None


def decodeCipSheet(fileBytes):
    position = 0
    while fileBytes[position] == 0:
        position += 1
    position += len(CIP_MARKER)
    while fileBytes[position] & 0x80:
        position += 1
    position += 1

    propertiesByte = fileBytes[position]
    dictionarySize = int.from_bytes(fileBytes[position + 1:position + 5], "little")
    position += 5 + 8

    filters = [{
        "id": lzma.FILTER_LZMA1,
        "lc": propertiesByte % 9,
        "lp": (propertiesByte // 9) % 5,
        "pb": propertiesByte // 45,
        "dict_size": dictionarySize,
    }]
    bitmap = lzma.LZMADecompressor(format=lzma.FORMAT_RAW, filters=filters).decompress(fileBytes[position:])
    pixelOffset = int.from_bytes(bitmap[10:14], "little")
    return bitmap[pixelOffset:pixelOffset + BASE_SHEET_SIZE * BASE_SHEET_SIZE * BYTES_PER_PIXEL]


def toTopDownRows(bottomUpPixels, sheetSize):
    rowBytes = sheetSize * BYTES_PER_PIXEL
    return [bytearray(bottomUpPixels[(sheetSize - 1 - row) * rowBytes:(sheetSize - row) * rowBytes]) for row in range(sheetSize)]


def clearMagentaKey(rows):
    for row in rows:
        for offset in range(0, len(row), BYTES_PER_PIXEL):
            if row[offset + 3] == 0 or (row[offset] == 0xFF and row[offset + 1] == 0x00 and row[offset + 2] == 0xFF):
                row[offset:offset + BYTES_PER_PIXEL] = TRANSPARENT_PIXEL


def padCellRow(row, cellLeft, cellWidth):
    start = cellLeft * BYTES_PER_PIXEL
    end = (cellLeft + cellWidth) * BYTES_PER_PIXEL
    firstPixel = row[start:start + BYTES_PER_PIXEL]
    lastPixel = row[end - BYTES_PER_PIXEL:end]
    return firstPixel * EDGE_PADDING + row[start:end] + lastPixel * EDGE_PADDING


def buildPaddedAtlas(rows, cellWidth, cellHeight):
    columns = BASE_SHEET_SIZE // cellWidth
    cellRows = BASE_SHEET_SIZE // cellHeight
    paddedCellHeight = cellHeight + EDGE_PADDING * 2
    atlasRows = []
    for cellRow in range(cellRows):
        top = cellRow * cellHeight
        paddedRows = []
        for rowInCell in range(-EDGE_PADDING, cellHeight + EDGE_PADDING):
            sourceRow = rows[top + min(max(rowInCell, 0), cellHeight - 1)]
            paddedRows.append(b"".join(padCellRow(sourceRow, column * cellWidth, cellWidth) for column in range(columns)))
        atlasRows.extend(paddedRows)
    atlasWidth = columns * (cellWidth + EDGE_PADDING * 2)
    return b"".join(atlasRows), atlasWidth, cellRows * paddedCellHeight


def scaleWithXbrz(pixels, width, height, scale):
    scalerProcess.stdin.write(struct.pack("<II", width, height))
    scalerProcess.stdin.write(pixels)
    scalerProcess.stdin.flush()
    expectedBytes = width * height * scale * scale * BYTES_PER_PIXEL
    scaled = scalerProcess.stdout.read(expectedBytes)
    if len(scaled) != expectedBytes:
        raise RuntimeError("xbrz scaler returned incomplete data")
    return scaled


def extractScaledSheet(scaledAtlas, atlasWidth, cellWidth, cellHeight, scale):
    columns = BASE_SHEET_SIZE // cellWidth
    cellRows = BASE_SHEET_SIZE // cellHeight
    scaledAtlasRowBytes = atlasWidth * scale * BYTES_PER_PIXEL
    paddedCellWidth = (cellWidth + EDGE_PADDING * 2) * scale
    paddedCellHeight = (cellHeight + EDGE_PADDING * 2) * scale
    scaledCellWidthBytes = cellWidth * scale * BYTES_PER_PIXEL
    croppedPadding = EDGE_PADDING * scale

    sheetRows = []
    for cellRow in range(cellRows):
        for rowInCell in range(cellHeight * scale):
            atlasRow = cellRow * paddedCellHeight + croppedPadding + rowInCell
            rowStart = atlasRow * scaledAtlasRowBytes
            pieces = []
            for column in range(columns):
                pieceStart = rowStart + (column * paddedCellWidth + croppedPadding) * BYTES_PER_PIXEL
                pieces.append(scaledAtlas[pieceStart:pieceStart + scaledCellWidthBytes])
            sheetRows.append(b"".join(pieces))
    return sheetRows


def encodeBitmap(topDownRows, sheetSize):
    pixelBytes = b"".join(reversed(topDownRows))
    fileHeader = struct.pack("<2sIHHI", b"BM", BITMAP_HEADER_SIZE + len(pixelBytes), 0, 0, BITMAP_HEADER_SIZE)
    infoHeader = struct.pack("<IiiHHIIiiII", 40, sheetSize, sheetSize, 1, 32, 0, len(pixelBytes), 2835, 2835, 0, 0)
    return fileHeader + infoHeader + pixelBytes


def encodeSevenBitInteger(value):
    encoded = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            encoded.append(byte | 0x80)
            continue
        encoded.append(byte)
        return bytes(encoded)


def encodeCipSheet(bitmapBytes):
    compressed = lzma.compress(bitmapBytes, format=lzma.FORMAT_ALONE, preset=6)
    sizeBytes = encodeSevenBitInteger(len(compressed))
    paddingLength = CIP_HEADER_SIZE - len(CIP_MARKER) - len(sizeBytes)
    return bytes(paddingLength) + CIP_MARKER + sizeBytes + compressed


def startScaler(scalerPath, scale):
    global scalerProcess
    scalerProcess = subprocess.Popen([str(scalerPath), str(scale)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def convertSheet(task):
    sourcePath, targetPath, layout, scale = task
    if targetPath.exists() and targetPath.stat().st_mtime >= sourcePath.stat().st_mtime:
        return "skipped"

    cellWidth, cellHeight = LAYOUT_SIZES.get(layout, LAYOUT_SIZES[0])
    rows = toTopDownRows(decodeCipSheet(sourcePath.read_bytes()), BASE_SHEET_SIZE)
    clearMagentaKey(rows)
    atlas, atlasWidth, atlasHeight = buildPaddedAtlas(rows, cellWidth, cellHeight)
    scaledAtlas = scaleWithXbrz(atlas, atlasWidth, atlasHeight, scale)
    sheetRows = extractScaledSheet(scaledAtlas, atlasWidth, cellWidth, cellHeight, scale)
    temporaryPath = targetPath.with_suffix(targetPath.suffix + ".tmp")
    temporaryPath.write_bytes(encodeCipSheet(encodeBitmap(sheetRows, BASE_SHEET_SIZE * scale)))
    os.replace(temporaryPath, targetPath)
    return "converted"


def defaultScalerPath():
    scalerName = "xbrz_raw.exe" if sys.platform.startswith("win") else "xbrz_raw"
    return Path(__file__).resolve().parent / scalerName


def copySupportFiles(sourceDirectory, targetDirectory, spriteFiles):
    for sourceFile in sourceDirectory.iterdir():
        if not sourceFile.is_file() or sourceFile.name in spriteFiles or sourceFile.name == "catalog-content.json":
            continue
        targetFile = targetDirectory / sourceFile.name
        if targetFile.exists() and targetFile.stat().st_mtime >= sourceFile.stat().st_mtime:
            continue
        shutil.copy2(sourceFile, targetFile)


def writeCatalog(catalog, targetDirectory, scale):
    entries = [entry for entry in catalog if entry.get("type") != SPRITE_SCALE_CATALOG_TYPE]
    entries.append({"type": SPRITE_SCALE_CATALOG_TYPE, "scale": scale})
    (targetDirectory / "catalog-content.json").write_text(json.dumps(entries, indent=2))


def parseArguments():
    parser = argparse.ArgumentParser(description="Generate HD (xBRZ upscaled) sprite sheets for the OTClient protobuf assets.")
    parser.add_argument("--source", required=True, type=Path, help="original assets folder, e.g. data/things/1511")
    parser.add_argument("--target", type=Path, help="HD assets folder (default: <source>_hd)")
    parser.add_argument("--scale", type=int, default=2, choices=[2, 3, 4])
    parser.add_argument("--scaler", type=Path, default=defaultScalerPath(), help="path to xbrz_raw executable")
    parser.add_argument("--workers", type=int, default=max(1, (os.cpu_count() or 2) - 1))
    return parser.parse_args()


def main():
    arguments = parseArguments()
    sourceDirectory = arguments.source.resolve()
    targetDirectory = (arguments.target or Path(str(arguments.source).rstrip("/\\") + "_hd")).resolve()
    catalogPath = sourceDirectory / "catalog-content.json"

    if not catalogPath.exists():
        sys.exit(f"catalog-content.json not found in {sourceDirectory}")
    if not arguments.scaler.exists():
        sys.exit(f"scaler not found: {arguments.scaler}")

    catalog = json.loads(catalogPath.read_text())
    spriteEntries = [entry for entry in catalog if entry.get("type") == "sprite"]
    targetDirectory.mkdir(parents=True, exist_ok=True)
    copySupportFiles(sourceDirectory, targetDirectory, {entry["file"] for entry in spriteEntries})

    tasks = [
        (sourceDirectory / entry["file"], targetDirectory / entry["file"], entry.get("spritetype", 0), arguments.scale)
        for entry in spriteEntries
        if (sourceDirectory / entry["file"]).exists()
    ]

    startedAt = time.time()
    results = {"converted": 0, "skipped": 0}
    with multiprocessing.Pool(arguments.workers, initializer=startScaler, initargs=(arguments.scaler, arguments.scale)) as pool:
        for index, result in enumerate(pool.imap_unordered(convertSheet, tasks, chunksize=4), start=1):
            results[result] += 1
            if index % 100 == 0 or index == len(tasks):
                print(f"{index}/{len(tasks)} sheets ({results['converted']} converted, {results['skipped']} up to date) - {time.time() - startedAt:.0f}s", flush=True)

    writeCatalog(catalog, targetDirectory, arguments.scale)
    print(f"Done. HD assets written to {targetDirectory}")


if __name__ == "__main__":
    main()
