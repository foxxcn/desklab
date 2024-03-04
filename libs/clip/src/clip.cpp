#include "../dacap_clip/clip.h"

extern "C" bool _set_text(const char* text) {
    return clip::set_text(text);
}

extern "C" bool _get_text(char** text) {
    std::string value;
    bool result = clip::get_text(value);
    if (result) {
        *text = (char*)malloc(value.size() + 1);
        strcpy(*text, value.c_str());
    }
    return result;
}

extern "C" bool _has_text() {
    return clip::has(clip::text_format());
}
