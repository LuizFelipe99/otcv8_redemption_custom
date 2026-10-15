#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#include "xbrz/xbrz.h"

namespace
{
    bool readExactly(void* destination, const size_t byteCount)
    {
        return std::fread(destination, 1, byteCount, stdin) == byteCount;
    }

    bool writeExactly(const void* source, const size_t byteCount)
    {
        return std::fwrite(source, 1, byteCount, stdout) == byteCount;
    }

    void useBinaryStreams()
    {
#ifdef _WIN32
        _setmode(_fileno(stdin), _O_BINARY);
        _setmode(_fileno(stdout), _O_BINARY);
#endif
    }
}

int main(const int argumentCount, char** arguments)
{
    if (argumentCount != 2) {
        std::fprintf(stderr, "usage: xbrz_raw <scale 2-6>\n");
        std::fprintf(stderr, "stdin: repeated [uint32 width][uint32 height][width*height BGRA pixels]\n");
        return 1;
    }

    const int scaleFactor = std::atoi(arguments[1]);
    if (scaleFactor < 2 || scaleFactor > 6) {
        std::fprintf(stderr, "scale must be between 2 and 6\n");
        return 1;
    }

    useBinaryStreams();

    std::vector<uint32_t> sourcePixels;
    std::vector<uint32_t> scaledPixels;

    while (true) {
        uint32_t dimensions[2];
        if (!readExactly(dimensions, sizeof(dimensions))) {
            return 0;
        }

        const uint32_t width = dimensions[0];
        const uint32_t height = dimensions[1];
        sourcePixels.resize(static_cast<size_t>(width) * height);
        scaledPixels.resize(sourcePixels.size() * scaleFactor * scaleFactor);

        if (!readExactly(sourcePixels.data(), sourcePixels.size() * sizeof(uint32_t))) {
            std::fprintf(stderr, "truncated pixel data\n");
            return 1;
        }

        xbrz::scale(scaleFactor, sourcePixels.data(), scaledPixels.data(), static_cast<int>(width), static_cast<int>(height), xbrz::ColorFormat::ARGB);

        if (!writeExactly(scaledPixels.data(), scaledPixels.size() * sizeof(uint32_t))) {
            return 1;
        }
        std::fflush(stdout);
    }
}
