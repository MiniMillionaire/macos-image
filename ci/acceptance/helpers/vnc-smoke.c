#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <openssl/bn.h>
#include <arpa/inet.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <math.h>
#include <unistd.h>

static void require(int valid, const char *message) {
    if (!valid) { fprintf(stderr, "%s\n", message); exit(1); }
}

static void transfer(int fd, void *data, size_t size, int writing) {
    uint8_t *bytes = data;
    while (size) {
        ssize_t count = writing ? write(fd, bytes, size) : read(fd, bytes, size);
        require(count > 0, "Incomplete RFB transfer");
        bytes += count;
        size -= (size_t)count;
    }
}

static uint32_t integer32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
           ((uint32_t)bytes[2] << 8) | bytes[3];
}

static void authenticate_ard(int fd, const char *password) {
    uint8_t header[4], modulusBytes[512], peerBytes[512], publicBytes[512], sharedBytes[512];
    transfer(fd, header, sizeof(header), 0);
    unsigned generator = ((unsigned)header[0] << 8) | header[1];
    unsigned size = ((unsigned)header[2] << 8) | header[3];
    require(size >= 16 && size <= 512 && generator > 1 && strlen(password) < 64, "Invalid ARD parameters");
    transfer(fd, modulusBytes, size, 0);
    transfer(fd, peerBytes, size, 0);
    BN_CTX *context = BN_CTX_new();
    BIGNUM *modulus = BN_bin2bn(modulusBytes, size, NULL), *peer = BN_bin2bn(peerBytes, size, NULL);
    BIGNUM *base = BN_new(), *secret = BN_new(), *public = BN_new(), *shared = BN_new();
    BIGNUM *limit = modulus ? BN_dup(modulus) : NULL;
    require(context && modulus && peer && base && secret && public && shared && limit, "ARD allocation failed");
    require(BN_sub_word(limit, 1) && BN_set_word(base, generator) &&
            BN_cmp(peer, BN_value_one()) > 0 && BN_cmp(peer, limit) < 0 && BN_cmp(base, limit) < 0,
            "Invalid ARD peer key");
    require(BN_sub_word(limit, 2) && BN_priv_rand_range(secret, limit) && BN_add_word(secret, 2) &&
            BN_mod_exp(public, base, secret, modulus, context) &&
            BN_mod_exp(shared, peer, secret, modulus, context) &&
            BN_bn2binpad(public, publicBytes, size) == (int)size &&
            BN_bn2binpad(shared, sharedBytes, size) == (int)size, "ARD key exchange failed");
    uint8_t key[CC_MD5_DIGEST_LENGTH], plain[128], encrypted[128];
    CC_MD5(sharedBytes, size, key);
    arc4random_buf(plain, sizeof(plain));
    memcpy(plain, "admin", 6);
    memcpy(plain + 64, password, strlen(password) + 1);
    size_t produced = 0;
    require(CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode, key, sizeof(key), NULL,
                    plain, sizeof(plain), encrypted, sizeof(encrypted), &produced) == kCCSuccess &&
            produced == sizeof(encrypted), "ARD encryption failed");
    transfer(fd, encrypted, sizeof(encrypted), 1);
    transfer(fd, publicBytes, size, 1);
    BN_clear_free(secret); BN_clear_free(shared);
    BN_free(modulus); BN_free(peer); BN_free(base); BN_free(public); BN_free(limit); BN_CTX_free(context);
}

static void frame(int fd, unsigned width, unsigned height, unsigned x, unsigned y, int verify) {
    uint8_t request[10] = {3, 0, 0, 0, 0, 0, width >> 8, width, height >> 8, height};
    transfer(fd, request, sizeof(request), 1);
    uint8_t update[4];
    transfer(fd, update, sizeof(update), 0);
    require(update[0] == 0, "Expected framebuffer update");
    unsigned rectangles = ((unsigned)update[2] << 8) | update[3];
    require(rectangles > 0 && rectangles <= 64, "Invalid framebuffer rectangle count");
    int sampled = 0, matched = 0;
    uint8_t actual[3] = {0};
    uint8_t *capture = calloc((size_t)width * height, 3);
    require(capture != NULL, "Capture allocation failed");
    for (unsigned index = 0; index < rectangles; index++) {
        uint8_t rectangle[12];
        transfer(fd, rectangle, sizeof(rectangle), 0);
        unsigned rx = ((unsigned)rectangle[0] << 8) | rectangle[1];
        unsigned ry = ((unsigned)rectangle[2] << 8) | rectangle[3];
        unsigned rw = ((unsigned)rectangle[4] << 8) | rectangle[5];
        unsigned rh = ((unsigned)rectangle[6] << 8) | rectangle[7];
        require(integer32(rectangle + 8) == 0 && rw > 0 && rh > 0 && rx + rw <= width && ry + rh <= height,
                "Invalid raw framebuffer rectangle");
        uint8_t *row = malloc((size_t)rw * 4);
        require(row != NULL, "Frame allocation failed");
        for (unsigned line = 0; line < rh; line++) {
            transfer(fd, row, (size_t)rw * 4, 0);
            for (unsigned column = 0; column < rw; column++) {
                size_t offset = ((size_t)(ry + line) * width + rx + column) * 3;
                capture[offset] = row[column * 4 + 2];
                capture[offset + 1] = row[column * 4 + 1];
                capture[offset + 2] = row[column * 4];
            }
            if (y == ry + line && x >= rx && x < rx + rw) {
                const uint8_t *pixel = row + (x - rx) * 4;
                matched = pixel[0] >= 231 && pixel[1] <= 24 && pixel[2] >= 231;
                actual[0] = pixel[2]; actual[1] = pixel[1]; actual[2] = pixel[0];
                sampled = 1;
            }
        }
        free(row);
    }
    const char *capturePath = verify ? getenv("VNC_CAPTURE_PATH") : NULL;
    if (capturePath != NULL) {
        FILE *output = fopen(capturePath, "wx");
        require(output != NULL, "Create diagnostic framebuffer failed");
        fprintf(output, "P6\n%u %u\n255\n", width, height);
        require(fwrite(capture, 3, (size_t)width * height, output) == (size_t)width * height,
                "Write diagnostic framebuffer failed");
        require(fclose(output) == 0, "Close diagnostic framebuffer failed");
    }
    free(capture);
    if (!verify) return;
    require(sampled, "Witness target was not captured");
    if (!matched) fprintf(stderr, "Witness pixel at (%u,%u): RGB %u,%u,%u\n", x, y, actual[0], actual[1], actual[2]);
    require(matched, "Witness pixel mismatch");
}

static void observe_pointer(unsigned x, unsigned y, int *matched) {
    const char *command = getenv("VNC_POINTER_COMMAND");
    require(command != NULL, "Pointer observation command is required");
    int descriptors[2];
    require(pipe(descriptors) == 0, "Pointer observation pipe failed");
    pid_t child = fork();
    require(child >= 0, "Pointer observation fork failed");
    if (child == 0) {
        close(descriptors[0]);
        if (dup2(descriptors[1], STDOUT_FILENO) < 0) _exit(127);
        close(descriptors[1]);
        execl(command, command, (char *)NULL);
        _exit(127);
    }
    close(descriptors[1]);
    FILE *input = fdopen(descriptors[0], "r");
    require(input != NULL, "Pointer observation stream failed");
    double actualX, actualY;
    int fields = fscanf(input, "%lf %lf", &actualX, &actualY);
    fclose(input);
    int status;
    require(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0 && fields == 2,
            "Pointer observation failed");
    *matched = fabs(actualX - x) < 0.5 && fabs(actualY - y) < 0.5;
    if (!*matched) fprintf(stderr, "Pointer expected (%u,%u), observed (%.1f,%.1f)\n", x, y, actualX, actualY);
}

int main(int argc, char **argv) {
    require(argc == 3 || argc == 9, "Usage: vnc-smoke IP password [x y focus-x logical-width logical-height nonce]");
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    require(fd >= 0, "Create socket failed");
    struct timeval timeout = {8, 0};
    require(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0, "Receive timeout failed");
    require(setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0, "Send timeout failed");
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons(5900)};
    require(inet_pton(AF_INET, argv[1], &address.sin_addr) == 1, "Invalid IP");
    require(connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0, "Connect failed");
    uint8_t banner[12];
    transfer(fd, banner, sizeof(banner), 0);
    require(memcmp(banner, "RFB 003.", 8) == 0, "Unexpected RFB version");
    char version[] = "RFB 003.008\n";
    transfer(fd, version, 12, 1);
    uint8_t count = 0, types[255];
    transfer(fd, &count, 1, 0);
    require(count > 0, "No RFB security types");
    transfer(fd, types, count, 0);
    const char *method = getenv("VNC_AUTH");
    uint8_t selected = method && strcmp(method, "ard") == 0 ? 30 : 2;
    require(memchr(types, selected, count) != NULL, "Configured VNC authentication unavailable");
    transfer(fd, &selected, 1, 1);
    if (selected == 30) {
        authenticate_ard(fd, argv[2]);
    } else {
    uint8_t challenge[16], response[16], key[8] = {0};
    transfer(fd, challenge, sizeof(challenge), 0);
    size_t length = strlen(argv[2]);
    for (size_t i = 0; i < 8 && i < length; i++) {
        uint8_t value = (uint8_t)argv[2][i];
        for (int bit = 0; bit < 8; bit++) key[i] |= ((value >> bit) & 1) << (7 - bit);
    }
    size_t produced = 0;
    require(CCCrypt(kCCEncrypt, kCCAlgorithmDES, kCCOptionECBMode, key, sizeof(key), NULL,
                    challenge, sizeof(challenge), response, sizeof(response), &produced) == kCCSuccess
            && produced == sizeof(response), "VNC challenge encryption failed");
    transfer(fd, response, sizeof(response), 1);
    }
    uint8_t result[4];
    transfer(fd, result, sizeof(result), 0);
    uint32_t status = integer32(result);
    if (status != 0) {
        printf("{\"authenticated\":false,\"status\":%u}\n", status);
        close(fd);
        return 2;
    }
    uint8_t shared = 1, server[24];
    transfer(fd, &shared, 1, 1);
    transfer(fd, server, sizeof(server), 0);
    unsigned width = (server[0] << 8) | server[1];
    unsigned height = (server[2] << 8) | server[3];
    uint32_t nameLength = integer32(server + 20);
    require(width > 0 && height > 0 && width <= 8192 && height <= 8192 && nameLength <= 4096,
            "Invalid RFB framebuffer");
    char name[4096];
    transfer(fd, name, nameLength, 0);
    if (argc == 9) {
        unsigned logicalWidth = (unsigned)atoi(argv[6]), logicalHeight = (unsigned)atoi(argv[7]);
        require(logicalWidth > 0 && logicalHeight > 0, "Invalid logical dimensions");
        unsigned x = (unsigned)atoi(argv[3]) * width / logicalWidth;
        unsigned y = (unsigned)atoi(argv[4]) * height / logicalHeight;
        unsigned focusX = (unsigned)atoi(argv[5]) * width / logicalWidth;
        require(x < width && y < height && focusX < width, "Invalid pointer target");
        uint8_t format[20] = {0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0};
        uint8_t encodings[8] = {2, 0, 0, 1, 0, 0, 0, 0};
        transfer(fd, format, sizeof(format), 1);
        transfer(fd, encodings, sizeof(encodings), 1);
        frame(fd, width, height, x, y, 1);
        unsigned positions[2] = {focusX, x};
        for (unsigned index = 0; index < 2; index++) {
            uint8_t pointer[6] = {5, 0, positions[index] >> 8, positions[index], y >> 8, y};
            int matched = 0;
            for (unsigned attempt = 0; attempt < 12 && !matched; attempt++) {
                transfer(fd, pointer, sizeof(pointer), 1);
                usleep(1000000);
                frame(fd, width, height, x, y, 0);
                observe_pointer(positions[index] * logicalWidth / width, y * logicalHeight / height, &matched);
            }
            require(matched, "Guest pointer did not reach target");
            pointer[1] = 1;
            transfer(fd, pointer, sizeof(pointer), 1);
            usleep(600000);
            frame(fd, width, height, x, y, 0);
            pointer[1] = 0;
            transfer(fd, pointer, sizeof(pointer), 1);
            usleep(600000);
            frame(fd, width, height, x, y, 0);
        }
        require(strlen(argv[8]) == 32, "Invalid witness nonce");
        for (const char *character = argv[8]; *character; character++) {
            require((*character >= '0' && *character <= '9') || (*character >= 'a' && *character <= 'f'), "Invalid nonce character");
            uint8_t keyEvent[8] = {4, 1, 0, 0, 0, 0, 0, (uint8_t)*character};
            transfer(fd, keyEvent, sizeof(keyEvent), 1);
            keyEvent[1] = 0;
            transfer(fd, keyEvent, sizeof(keyEvent), 1);
            usleep(80000);
            frame(fd, width, height, x, y, 0);
        }
        usleep(600000);
    }
    printf("{\"authenticated\":true,\"securityType\":%u,\"width\":%u,\"height\":%u}\n", selected, width, height);
    close(fd);
    return 0;
}
