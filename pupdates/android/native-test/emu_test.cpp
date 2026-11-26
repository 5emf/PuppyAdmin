// Runs a core for N frames and reports speed, a picture checksum and (Game Boy) link-port text.
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <algorithm>

#include "emu_core.h"

static std::string slurp(const char *path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) { fprintf(stderr, "cannot read %s\n", path); exit(2); }
    std::stringstream s;
    s << f.rdbuf();
    return s.str();
}

static void savePpm(const char *path, const uint8_t *rgba, int w, int h) {
    FILE *f = fopen(path, "wb");
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int i = 0; i < w * h; i++) fwrite(rgba + i * 4, 1, 3, f);
    fclose(f);
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: emu_test gb|gba MODULE ROM FRAMES [BIOS] | doom WAD FRAMES\n"); return 2; }
    std::string kind = argv[1];
    if (kind == "games") {   // emu_test games minigames.lua FRAMES: every game, random input, no errors allowed
        std::string src = slurp(argv[2]);
        char e[512] = {0};
        if (!gm_open(src.data(), src.size(), e, sizeof(e))) { printf("OPEN FAILED: %s\n", e); return 1; }
        std::vector<std::string> out;
        std::string err;
        gm_call("list", nullptr, 0, out, err);
        std::vector<std::string> ids;
        std::stringstream ls(out[0]);
        for (std::string line; std::getline(ls, line);) ids.push_back(line.substr(0, line.find('\t')));
        const char *acts[] = {"left", "right", "up", "down", "rotate", "drop"};
        int frames = atoi(argv[3]);
        srand(7);
        for (auto &id : ids) {
            const char *a1[] = {id.c_str()};
            gm_call("select", a1, 1, out, err);
            const char *seed[] = {"42"};
            if (!gm_call("new", seed, 1, out, err)) { printf("%s new: %s\n", id.c_str(), err.c_str()); return 1; }
            size_t kindsSeen = 0, actorsMax = 0;
            std::string hud, score, over;
            int games = 1;
            for (int i = 0; i < frames; i++) {
                if (rand() % 6 == 0) {
                    const char *in[] = {acts[rand() % 6], (rand() % 2) ? "1" : "0"};
                    if (!gm_call("input", in, 2, out, err)) { printf("%s input: %s\n", id.c_str(), err.c_str()); return 1; }
                }
                const char *dt[] = {"0.0166"};
                if (!gm_call("update", dt, 1, out, err)) { printf("%s update: %s\n", id.c_str(), err.c_str()); return 1; }
                const char *sp[] = {"1"};
                if (!gm_call("frame", sp, 1, out, err)) { printf("%s frame: %s\n", id.c_str(), err.c_str()); return 1; }
                if (out.size() != 11) { printf("%s frame returned %zu values\n", id.c_str(), out.size()); return 1; }
                if (!out[1].empty()) kindsSeen += std::count(out[1].begin(), out[1].end(), ';') + 1;
                actorsMax = std::max(actorsMax, out[2].empty() ? 0 : (size_t)std::count(out[2].begin(), out[2].end(), ';') + 1);
                hud = out[3]; over = out[5]; score = out[6];
                if (over == "1") { gm_call("new", seed, 1, out, err); games++; }
            }
            printf("%-8s ok: %d frames, %d games, %zu cell kinds, up to %zu sprites, last hud \"%s\"\n", id.c_str(), frames, games, kindsSeen, actorsMax, hud.c_str());
        }
        return 0;
    }
    std::vector<uint8_t> px(320 * 200 * 4);
    char err[512] = {0};
    auto t0 = std::chrono::steady_clock::now();
    int frames = 0, w = 0, h = 0;
    long audio = 0;
    if (kind == "doom") {
        if (!doom_open(argv[2], ".", err, sizeof(err))) { printf("OPEN FAILED: %s\n", err); return 1; }
        frames = atoi(argv[3]);
        for (int i = 0; i < frames; i++) {
            if (i == 40) doom_key(1, 13);  // Enter on the title: opens the menu
            if (i == 42) doom_key(0, 13);
            int r = doom_tick(px.data());
            if (r != 1) { printf("STOPPED %d: %s\n", r, doom_error()); return 1; }
            int16_t buf[2 * 735];
            doom_audio(buf, 735);
        }
        w = 320; h = 200;
    } else {
        std::string mod = slurp(argv[2]), rom = slurp(argv[3]), bios = argc > 5 ? slurp(argv[5]) : "";
        int k = kind == "gb" ? EMU_GB : EMU_GBA;
        if (!lemu_open(k, mod.data(), mod.size(), rom.data(), rom.size(), bios.data(), bios.size(), nullptr, 0, err, sizeof(err))) {
            printf("OPEN FAILED: %s\n", err); return 1;
        }
        w = lemu_width(); h = lemu_height();
        frames = atoi(argv[4]);
        int16_t abuf[8192];
        for (int i = 0; i < frames; i++) {
            lemu_keys(i % 120 < 10 && i > 200 ? 8 : 0);  // tap Start now and then
            if (!lemu_frame(px.data(), (i & 1) || i == frames - 1, err, sizeof(err))) { printf("FRAME FAILED at %d: %s\n", i, err); return 1; }
            audio += lemu_audio(abuf, 8192);
        }
        uint8_t *save = nullptr;
        size_t n = lemu_save(&save);
        printf("save bytes: %zu\n", n);
        free(save);
    }
    double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    unsigned long sum = 0;
    int colours = 0;
    std::vector<int> seen(1 << 15, 0);
    for (int i = 0; i < w * h; i++) {
        const uint8_t *p = &px[i * 4];
        sum = sum * 31 + p[0] + p[1] * 7 + p[2] * 13;
        int key = (p[0] >> 3) << 10 | (p[1] >> 3) << 5 | (p[2] >> 3);
        if (!seen[key]++) colours++;
    }
    printf("%s: %d frames in %.2f s (%.1f fps), %d colours, checksum %lu, audio samples %ld\n", kind.c_str(), frames, secs,
           frames / secs, colours, sum, audio);
    savePpm(("last_" + kind + ".ppm").c_str(), px.data(), w, h);
    return 0;
}
