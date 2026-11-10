#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <tuple>
#include <vector>
#include <zlib.h>

namespace {

constexpr uint8_t NODE_START = 0xFE;
constexpr uint8_t NODE_END = 0xFF;
constexpr uint8_t NODE_ESCAPE = 0xFD;

constexpr uint8_t OTBM_TILE_AREA = 4;
constexpr uint8_t OTBM_TILE = 5;
constexpr uint8_t OTBM_ITEM = 6;
constexpr uint8_t OTBM_HOUSETILE = 14;

constexpr uint8_t OTBM_ATTR_TILE_FLAGS = 3;
constexpr uint8_t OTBM_ATTR_ITEM = 9;

constexpr uint8_t CATEGORY_COMMON = 0;
constexpr uint8_t CATEGORY_GROUND = 1;

constexpr uint8_t ITEM_FLAG_NOT_WALKABLE = 1;
constexpr uint8_t ITEM_FLAG_NOT_PATHABLE = 2;

constexpr uint8_t MINIMAP_TILE_WAS_SEEN = 1;
constexpr uint8_t MINIMAP_TILE_NOT_PATHABLE = 2;
constexpr uint8_t MINIMAP_TILE_NOT_WALKABLE = 4;

constexpr int MINIMAP_BLOCK_SIZE = 64;
constexpr int MINIMAP_TILE_BYTES = 3;
constexpr int MINIMAP_BLOCK_BYTES = MINIMAP_BLOCK_SIZE * MINIMAP_BLOCK_SIZE * MINIMAP_TILE_BYTES;
constexpr uint8_t DEFAULT_TILE_COLOR = 255;
constexpr uint8_t DEFAULT_TILE_SPEED = 10;
constexpr int DEFAULT_GROUND_SPEED = 100;
constexpr uint32_t OTMM_SIGNATURE = 0x4D4D544F;
constexpr uint16_t OTMM_VERSION = 1;
constexpr int COMPRESSION_LEVEL = 9;

struct ItemAppearance
{
    uint8_t category{ CATEGORY_COMMON };
    uint8_t movementFlags{ 0 };
    uint8_t minimapColor{ 0 };
    uint16_t groundSpeed{ 0 };
};

struct TilePosition
{
    uint16_t x{ 0 };
    uint16_t y{ 0 };
    uint8_t z{ 0 };
};

using BlockKey = std::tuple<uint8_t, uint16_t, uint16_t>;
using MinimapBlockData = std::vector<uint8_t>;

std::vector<ItemAppearance> loadItemAppearances(const std::string& tablePath)
{
    std::ifstream tableFile(tablePath, std::ios::binary);
    if (!tableFile) {
        throw std::runtime_error("unable to open item table " + tablePath);
    }

    std::vector<ItemAppearance> appearances(65536);
    std::array<uint8_t, 7> record{};
    while (tableFile.read(reinterpret_cast<char*>(record.data()), record.size())) {
        const uint16_t itemId = record[0] | (record[1] << 8);
        appearances[itemId] = { record[2], record[3], record[4], static_cast<uint16_t>(record[5] | (record[6] << 8)) };
    }
    return appearances;
}

std::vector<uint8_t> readWholeFile(const std::string& filePath)
{
    std::ifstream inputFile(filePath, std::ios::binary | std::ios::ate);
    if (!inputFile) {
        throw std::runtime_error("unable to open map " + filePath);
    }

    const auto fileSize = static_cast<size_t>(inputFile.tellg());
    std::vector<uint8_t> content(fileSize);
    inputFile.seekg(0);
    inputFile.read(reinterpret_cast<char*>(content.data()), static_cast<std::streamsize>(fileSize));
    return content;
}

class MinimapBuilder
{
public:
    explicit MinimapBuilder(std::vector<ItemAppearance> appearances) : m_appearances(std::move(appearances)) {}

    void addTile(const TilePosition& position, const std::vector<uint16_t>& itemIds)
    {
        if (itemIds.empty()) {
            return;
        }

        MinimapBlockData& block = getBlock(position);
        const int tileIndex = ((position.y % MINIMAP_BLOCK_SIZE) * MINIMAP_BLOCK_SIZE + (position.x % MINIMAP_BLOCK_SIZE)) * MINIMAP_TILE_BYTES;
        block[tileIndex] = resolveTileFlags(itemIds);
        block[tileIndex + 1] = resolveTileColor(itemIds);
        block[tileIndex + 2] = resolveTileSpeed(itemIds);
        ++m_tileCount;
    }

    void save(const std::string& outputPath) const
    {
        std::ofstream outputFile(outputPath, std::ios::binary);
        if (!outputFile) {
            throw std::runtime_error("unable to create " + outputPath);
        }

        const std::string description = "OTMM 1.0";
        const uint16_t dataStart = static_cast<uint16_t>(4 + 2 + 2 + 4 + 2 + description.size());
        writeU32(outputFile, OTMM_SIGNATURE);
        writeU16(outputFile, dataStart);
        writeU16(outputFile, OTMM_VERSION);
        writeU32(outputFile, 0);
        writeU16(outputFile, static_cast<uint16_t>(description.size()));
        outputFile.write(description.data(), static_cast<std::streamsize>(description.size()));

        std::vector<uint8_t> compressBuffer(compressBound(MINIMAP_BLOCK_BYTES));
        for (const auto& [blockKey, blockData] : m_blocks) {
            const auto& [floor, blockX, blockY] = blockKey;
            uLongf compressedLength = compressBuffer.size();
            compress2(compressBuffer.data(), &compressedLength, blockData.data(), blockData.size(), COMPRESSION_LEVEL);

            writeU16(outputFile, blockX);
            writeU16(outputFile, blockY);
            outputFile.put(static_cast<char>(floor));
            writeU16(outputFile, static_cast<uint16_t>(compressedLength));
            outputFile.write(reinterpret_cast<const char*>(compressBuffer.data()), static_cast<std::streamsize>(compressedLength));
        }

        writeU16(outputFile, 65535);
        writeU16(outputFile, 65535);
        outputFile.put(static_cast<char>(255));
    }

    size_t tileCount() const { return m_tileCount; }
    size_t blockCount() const { return m_blocks.size(); }

private:
    MinimapBlockData& getBlock(const TilePosition& position)
    {
        const BlockKey blockKey{ position.z, position.x - position.x % MINIMAP_BLOCK_SIZE, position.y - position.y % MINIMAP_BLOCK_SIZE };
        auto existingBlock = m_blocks.find(blockKey);
        if (existingBlock != m_blocks.end()) {
            return existingBlock->second;
        }

        MinimapBlockData emptyBlock(MINIMAP_BLOCK_BYTES);
        for (int tileOffset = 0; tileOffset < MINIMAP_BLOCK_BYTES; tileOffset += MINIMAP_TILE_BYTES) {
            emptyBlock[tileOffset] = 0;
            emptyBlock[tileOffset + 1] = DEFAULT_TILE_COLOR;
            emptyBlock[tileOffset + 2] = DEFAULT_TILE_SPEED;
        }
        return m_blocks.emplace(blockKey, std::move(emptyBlock)).first->second;
    }

    uint8_t resolveTileFlags(const std::vector<uint16_t>& itemIds) const
    {
        uint8_t tileFlags = MINIMAP_TILE_WAS_SEEN;
        bool hasGround = false;
        for (const uint16_t itemId : itemIds) {
            const ItemAppearance& appearance = m_appearances[itemId];
            hasGround = hasGround || appearance.category == CATEGORY_GROUND;
            if (appearance.movementFlags & ITEM_FLAG_NOT_WALKABLE) {
                tileFlags |= MINIMAP_TILE_NOT_WALKABLE;
            }
            if (appearance.movementFlags & ITEM_FLAG_NOT_PATHABLE) {
                tileFlags |= MINIMAP_TILE_NOT_PATHABLE;
            }
        }

        if (!hasGround) {
            tileFlags |= MINIMAP_TILE_NOT_WALKABLE;
        }
        return tileFlags;
    }

    uint8_t resolveTileColor(const std::vector<uint16_t>& itemIds) const
    {
        std::vector<std::pair<uint8_t, int>> stackOrder;
        for (int stackIndex = 0; stackIndex < static_cast<int>(itemIds.size()); ++stackIndex) {
            const ItemAppearance& appearance = m_appearances[itemIds[stackIndex]];
            if (appearance.category == CATEGORY_COMMON) {
                continue;
            }
            stackOrder.emplace_back(appearance.category, stackIndex);
        }

        std::sort(stackOrder.rbegin(), stackOrder.rend());
        for (const auto& [category, stackIndex] : stackOrder) {
            const uint8_t minimapColor = m_appearances[itemIds[stackIndex]].minimapColor;
            if (minimapColor != 0) {
                return minimapColor;
            }
        }
        return 0;
    }

    uint8_t resolveTileSpeed(const std::vector<uint16_t>& itemIds) const
    {
        int groundSpeed = DEFAULT_GROUND_SPEED;
        for (const uint16_t itemId : itemIds) {
            const ItemAppearance& appearance = m_appearances[itemId];
            if (appearance.category == CATEGORY_GROUND) {
                groundSpeed = appearance.groundSpeed;
                break;
            }
        }
        return static_cast<uint8_t>(std::min(static_cast<int>(std::ceil(groundSpeed / 10.0)), 255));
    }

    static void writeU16(std::ofstream& outputFile, uint16_t value)
    {
        outputFile.put(static_cast<char>(value & 0xFF));
        outputFile.put(static_cast<char>(value >> 8));
    }

    static void writeU32(std::ofstream& outputFile, uint32_t value)
    {
        writeU16(outputFile, static_cast<uint16_t>(value & 0xFFFF));
        writeU16(outputFile, static_cast<uint16_t>(value >> 16));
    }

    std::vector<ItemAppearance> m_appearances;
    std::map<BlockKey, MinimapBlockData> m_blocks;
    size_t m_tileCount{ 0 };
};

class OtbmReader
{
public:
    OtbmReader(const std::vector<uint8_t>& content, MinimapBuilder& builder) : m_content(content), m_builder(builder) {}

    void read()
    {
        m_offset = 4;
        if (m_content.size() < 5 || m_content[m_offset] != NODE_START) {
            throw std::runtime_error("invalid OTBM file");
        }
        ++m_offset;
        walkNodes();
    }

private:
    struct NodeContext
    {
        TilePosition areaBase{};
        TilePosition tilePosition{};
        std::vector<uint16_t>* tileItems{ nullptr };
        bool insideItem{ false };
    };

    void walkNodes()
    {
        std::vector<NodeContext> contextStack(1);
        std::vector<uint8_t> nodeTypes;
        std::vector<std::vector<uint16_t>> tileItemStack;
        std::vector<TilePosition> tilePositionStack;

        nodeTypes.push_back(m_content[m_offset++]);
        std::vector<uint8_t> properties = readProperties();
        openNode(nodeTypes.back(), properties, contextStack, tileItemStack, tilePositionStack);

        while (!nodeTypes.empty() && m_offset < m_content.size()) {
            const uint8_t marker = m_content[m_offset++];
            if (marker == NODE_START) {
                nodeTypes.push_back(m_content[m_offset++]);
                properties = readProperties();
                openNode(nodeTypes.back(), properties, contextStack, tileItemStack, tilePositionStack);
                continue;
            }

            if (marker != NODE_END) {
                throw std::runtime_error("unexpected byte while walking nodes");
            }

            closeNode(nodeTypes.back(), contextStack, tileItemStack, tilePositionStack);
            nodeTypes.pop_back();
            properties = readProperties();
        }
    }

    std::vector<uint8_t> readProperties()
    {
        std::vector<uint8_t> properties;
        while (m_offset < m_content.size()) {
            const uint8_t currentByte = m_content[m_offset];
            if (currentByte == NODE_START || currentByte == NODE_END) {
                return properties;
            }
            if (currentByte == NODE_ESCAPE) {
                ++m_offset;
            }
            properties.push_back(m_content[m_offset++]);
        }
        return properties;
    }

    static uint16_t readU16(const std::vector<uint8_t>& bytes, size_t position)
    {
        return bytes[position] | (bytes[position + 1] << 8);
    }

    void openNode(uint8_t nodeType, const std::vector<uint8_t>& properties, std::vector<NodeContext>& contextStack,
                  std::vector<std::vector<uint16_t>>& tileItemStack, std::vector<TilePosition>& tilePositionStack)
    {
        NodeContext context = contextStack.back();

        if (nodeType == OTBM_TILE_AREA && properties.size() >= 5) {
            context.areaBase = { readU16(properties, 0), readU16(properties, 2), properties[4] };
            contextStack.push_back(context);
            return;
        }

        if ((nodeType == OTBM_TILE || nodeType == OTBM_HOUSETILE) && properties.size() >= 2) {
            const TilePosition tilePosition{ static_cast<uint16_t>(context.areaBase.x + properties[0]), static_cast<uint16_t>(context.areaBase.y + properties[1]), context.areaBase.z };
            tileItemStack.emplace_back(readInlineGround(nodeType, properties));
            tilePositionStack.push_back(tilePosition);
            context.insideItem = false;
            contextStack.push_back(context);
            return;
        }

        if (nodeType == OTBM_ITEM) {
            if (!context.insideItem && !tileItemStack.empty() && properties.size() >= 2) {
                tileItemStack.back().push_back(readU16(properties, 0));
            }
            context.insideItem = true;
            contextStack.push_back(context);
            return;
        }

        contextStack.push_back(context);
    }

    void closeNode(uint8_t nodeType, std::vector<NodeContext>& contextStack, std::vector<std::vector<uint16_t>>& tileItemStack,
                   std::vector<TilePosition>& tilePositionStack)
    {
        contextStack.pop_back();
        if (nodeType != OTBM_TILE && nodeType != OTBM_HOUSETILE) {
            return;
        }
        if (tileItemStack.empty()) {
            return;
        }

        m_builder.addTile(tilePositionStack.back(), tileItemStack.back());
        tileItemStack.pop_back();
        tilePositionStack.pop_back();
    }

    static std::vector<uint16_t> readInlineGround(uint8_t nodeType, const std::vector<uint8_t>& properties)
    {
        std::vector<uint16_t> itemIds;
        size_t position = nodeType == OTBM_HOUSETILE ? 6 : 2;
        while (position < properties.size()) {
            const uint8_t attribute = properties[position++];
            if (attribute == OTBM_ATTR_TILE_FLAGS) {
                position += 4;
                continue;
            }
            if (attribute == OTBM_ATTR_ITEM && position + 1 < properties.size()) {
                itemIds.push_back(readU16(properties, position));
                position += 2;
                continue;
            }
            break;
        }
        return itemIds;
    }

    const std::vector<uint8_t>& m_content;
    MinimapBuilder& m_builder;
    size_t m_offset{ 0 };
};

}

int main(int argumentCount, char** arguments)
{
    if (argumentCount < 4) {
        std::cerr << "usage: otbm_to_otmm <items.bin> <output.otmm> <map.otbm> [more maps...]" << std::endl;
        return 1;
    }

    try {
        MinimapBuilder builder(loadItemAppearances(arguments[1]));
        for (int mapIndex = 3; mapIndex < argumentCount; ++mapIndex) {
            const std::vector<uint8_t> mapContent = readWholeFile(arguments[mapIndex]);
            OtbmReader(mapContent, builder).read();
            std::cout << "loaded " << arguments[mapIndex] << " tiles so far: " << builder.tileCount() << std::endl;
        }
        builder.save(arguments[2]);
        std::cout << "saved " << builder.blockCount() << " blocks to " << arguments[2] << std::endl;
    } catch (const std::exception& error) {
        std::cerr << "error: " << error.what() << std::endl;
        return 1;
    }
    return 0;
}
