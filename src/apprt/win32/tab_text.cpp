// DirectWrite shapes a complete UTF-16 title in the configured UI family and
// falls back by text cluster. Direct2D paints color glyphs into a transparent
// scratch bitmap so tab fills, progress bars and system backdrops survive.
#define NOMINMAX
#include <windows.h>
#include <d2d1.h>
#include <dwrite.h>

template <typename T> static void release(T*& value) {
    if (value) value->Release();
    value = nullptr;
}

struct TabText {
    IDWriteFactory* write;
    ID2D1Factory* draw;
    ID2D1DCRenderTarget* target;
    ID2D1SolidColorBrush* brush;
    IDWriteTextFormat* format;
    LOGFONTW font;
    HDC dc;
    HBITMAP bitmap;
    HGDIOBJ original;
    void* pixels;
    int width, height;
};

extern "C" void madotty_tab_text_destroy(TabText* state) {
    if (!state) return;
    release(state->format);
    release(state->brush);
    release(state->target);
    release(state->draw);
    release(state->write);
    if (state->original) SelectObject(state->dc, state->original);
    if (state->bitmap) DeleteObject(state->bitmap);
    if (state->dc) DeleteDC(state->dc);
    HeapFree(GetProcessHeap(), 0, state);
}

extern "C" TabText* madotty_tab_text_create() {
    auto state = static_cast<TabText*>(HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(TabText)));
    if (!state) return nullptr;
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                   reinterpret_cast<IUnknown**>(&state->write))) ||
        FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &state->draw)) ||
        !(state->dc = CreateCompatibleDC(nullptr))) {
        madotty_tab_text_destroy(state);
        return nullptr;
    }
    return state;
}

static bool prepareTarget(TabText* state, int width, int height) {
    if (!state->target) {
        auto props = D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96, 96);
        if (FAILED(state->draw->CreateDCRenderTarget(&props, &state->target))) return false;
        state->target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    }
    if (!state->brush && FAILED(state->target->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0), &state->brush))) return false;
    if (state->width >= width && state->height >= height) return true;
    BITMAPINFO bitmapInfo{};
    bitmapInfo.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bitmapInfo.bmiHeader.biWidth = width > state->width ? width : state->width;
    bitmapInfo.bmiHeader.biHeight = -(height > state->height ? height : state->height);
    bitmapInfo.bmiHeader.biPlanes = 1;
    bitmapInfo.bmiHeader.biBitCount = 32;
    bitmapInfo.bmiHeader.biCompression = BI_RGB;
    void* pixels = nullptr;
    auto bitmap = CreateDIBSection(state->dc, &bitmapInfo, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (!bitmap) return false;
    auto previous = SelectObject(state->dc, bitmap);
    if (!previous || previous == HGDI_ERROR) {
        DeleteObject(bitmap);
        return false;
    }
    if (!state->original) state->original = previous;
    if (state->bitmap) DeleteObject(state->bitmap);
    state->bitmap = bitmap;
    state->pixels = pixels;
    state->width = bitmapInfo.bmiHeader.biWidth;
    state->height = -bitmapInfo.bmiHeader.biHeight;
    return true;
}

static bool prepareFont(TabText* state, HDC destination) {
    LOGFONTW font{};
    if (!GetObjectW(GetCurrentObject(destination, OBJ_FONT), sizeof(font), &font)) return false;
    if (state->format && !memcmp(&font, &state->font, sizeof(font))) return true;
    WCHAR locale[LOCALE_NAME_MAX_LENGTH]{};
    GetUserDefaultLocaleName(locale, LOCALE_NAME_MAX_LENGTH);
    IDWriteTextFormat* format = nullptr;
    if (FAILED(state->write->CreateTextFormat(font.lfFaceName, nullptr,
            static_cast<DWRITE_FONT_WEIGHT>(font.lfWeight), font.lfItalic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL, static_cast<float>(abs(font.lfHeight)), locale, &format))) return false;
    format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    release(state->format);
    state->format = format;
    state->font = font;
    return true;
}

extern "C" int madotty_tab_text_draw(TabText* state, HDC destination, const RECT* rect, const WCHAR* text,
                                     UINT32 length, COLORREF color, int center, int requireFit) {
    int width = rect->right - rect->left, height = rect->bottom - rect->top;
    if (width <= 0 || height <= 0) return true;
    if (!state || !prepareFont(state, destination) || !prepareTarget(state, width, height)) return false;
    IDWriteTextLayout* layout = nullptr;
    if (FAILED(state->write->CreateTextLayout(text, length, state->format, static_cast<float>(width),
                                              static_cast<float>(height), &layout))) return false;
    DWRITE_TEXT_METRICS metrics{};
    const bool fits = (center || requireFit) && SUCCEEDED(layout->GetMetrics(&metrics)) &&
                      metrics.widthIncludingTrailingWhitespace <= width;
    if (requireFit && !fits) {
        layout->Release();
        return false;
    }
    if (center && fits)
        layout->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
    RECT bounds{0, 0, width, height};
    HRESULT hr = state->target->BindDC(state->dc, &bounds);
    if (SUCCEEDED(hr)) {
        // EndDraw composites into the GDI DC. Start each label on transparent pixels.
        GdiFlush();
        auto row = static_cast<BYTE*>(state->pixels);
        for (int y = 0; y < height; ++y, row += state->width * 4) ZeroMemory(row, width * 4);
        state->brush->SetColor(D2D1::ColorF(GetRValue(color)/255.f, GetGValue(color)/255.f, GetBValue(color)/255.f));
        state->target->BeginDraw();
        state->target->Clear(D2D1::ColorF(0, 0, 0, 0));
        state->target->DrawTextLayout(D2D1::Point2F(0, 0), layout, state->brush,
            static_cast<D2D1_DRAW_TEXT_OPTIONS>(D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT | D2D1_DRAW_TEXT_OPTIONS_CLIP));
        hr = state->target->EndDraw();
    }
    layout->Release();
    if (hr == D2DERR_RECREATE_TARGET) {
        release(state->brush);
        release(state->target);
    }
    if (FAILED(hr)) return false;
    BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    return GdiAlphaBlend(destination, rect->left, rect->top, width, height, state->dc, 0, 0, width, height, blend);
}
