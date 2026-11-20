// Ghostty's terminal shader stages for Direct3D 12. The binding and input
// semantic conventions follow Wintty (MIT), commit b62d3cfe10d62058f831.
// See shaders.zig for the matching CPU-to-GPU layout.

cbuffer Uniforms : register(b0)
{
    column_major float4x4 projection_matrix : packoffset(c0);
    float2 screen_size : packoffset(c4.x);
    float2 cell_size : packoffset(c4.z);
    uint grid_size_packed : packoffset(c5.x);
    float4 grid_padding : packoffset(c6);
    uint padding_extend : packoffset(c7.x);
    float min_contrast : packoffset(c7.y);
    uint cursor_pos_packed : packoffset(c7.z);
    uint cursor_color_packed : packoffset(c7.w);
    uint background_packed : packoffset(c8.x);
    uint flags : packoffset(c8.y);
};

Texture2D<float4> texture_0 : register(t0);
Texture2D<float4> texture_1 : register(t1);
StructuredBuffer<uint> cell_backgrounds : register(t3);
SamplerState image_sampler : register(s0);

static const uint CURSOR_WIDTH_SHIFT = 4u;
static const uint LINEAR_BLENDING = 4u;
static const uint LINEAR_CORRECTION = 8u;

uint2 unpack_position(uint packed)
{
    return uint2(packed & 0xffffu, packed >> 16u);
}

float4 unpack_color(uint packed)
{
    return float4((packed >> uint4(0, 8, 16, 24)) & 255u) / 255.0;
}

float3 linearize(float3 color)
{
    return lerp(pow((color + 0.055) / 1.055, 2.4), color / 12.92,
                step(color, 0.04045));
}

float3 encode_srgb(float3 color)
{
    return lerp(pow(color, 1.0 / 2.4) * 1.055 - 0.055, color * 12.92,
                step(color, 0.0031308));
}

float4 load_color(float4 color, bool use_linear)
{
    if (use_linear) color.rgb = linearize(color.rgb);
    color.rgb *= color.a;
    return color;
}

float4 encode_premultiplied(float4 color)
{
    if (color.a > 0.0) color.rgb = encode_srgb(color.rgb / color.a) * color.a;
    return color;
}

bool linear_blending()
{
    return (flags & LINEAR_BLENDING) != 0u;
}

float luminance(float3 color)
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float4 contrast_color(float4 foreground, float4 background)
{
    float fg = luminance(foreground.rgb) + 0.05;
    float bg = luminance(background.rgb) + 0.05;
    if (max(fg, bg) / min(fg, bg) >= min_contrast) return foreground;
    return 1.05 / bg > bg / 0.05 ? float4(1, 1, 1, 1) : float4(0, 0, 0, 1);
}

float2 quad_corner(uint vertex)
{
    return float2(vertex & 1u, vertex >> 1u);
}

float4 full_screen_vs(uint vertex : SV_VertexID) : SV_Position
{
    return float4(vertex == 2u ? 3.0 : -1.0, vertex == 0u ? -3.0 : 1.0, 0.0, 1.0);
}

float4 bg_color_ps() : SV_Target
{
    return load_color(unpack_color(background_packed), linear_blending());
}

float4 cell_bg_ps(float4 position : SV_Position) : SV_Target
{
    int2 grid_size = int2(unpack_position(grid_size_packed));
    if (any(grid_size <= 0)) return 0;

    int2 cell = int2(floor((position.xy - grid_padding.wx) / cell_size));
    if ((cell.x < 0 && (padding_extend & 1u) == 0u) ||
        (cell.x >= grid_size.x && (padding_extend & 2u) == 0u) ||
        (cell.y < 0 && (padding_extend & 4u) == 0u) ||
        (cell.y >= grid_size.y && (padding_extend & 8u) == 0u))
        return 0;

    cell = clamp(cell, 0, grid_size - 1);
    uint color = cell_backgrounds[cell.y * grid_size.x + cell.x];
    return load_color(unpack_color(color), linear_blending());
}

struct CellTextInput
{
    uint2 glyph_pos : GLYPH_POS;
    uint2 glyph_size : GLYPH_SIZE;
    int2 bearings : BEARINGS;
    uint2 grid_pos : GRID_POS;
    float4 color : COLOR;
    uint atlas : ATLAS;
    uint bits : BOOLS;
};

struct CellTextVertex
{
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD;
    nointerpolation float4 foreground : COLOR0;
    nointerpolation float4 background : COLOR1;
    nointerpolation uint atlas : ATLAS;
};

CellTextVertex cell_text_vs(uint vertex : SV_VertexID, CellTextInput cell)
{
    float2 offset = float2(cell.bearings.x, cell_size.y - cell.bearings.y);
    float2 corner = float2(cell.glyph_size) * quad_corner(vertex);
    float2 position = cell_size * float2(cell.grid_pos) + offset + corner;

    CellTextVertex output;
    output.position = mul(projection_matrix, float4(position, 0.0, 1.0));
    output.tex_coord = float2(cell.glyph_pos) + corner;
    output.atlas = cell.atlas;
    output.foreground = load_color(cell.color, true);

    uint2 grid_size = unpack_position(grid_size_packed);
    uint bg_index = cell.grid_pos.y * grid_size.x + cell.grid_pos.x;
    float4 background = load_color(unpack_color(background_packed), true);
    float4 cell_background = 0;
    if (all(cell.grid_pos < grid_size))
        cell_background = load_color(unpack_color(cell_backgrounds[bg_index]), true);
    output.background = cell_background + background * (1.0 - cell_background.a);

    // Preserve explicitly exempt glyphs and cursor glyphs like the other backends.
    if (min_contrast > 1.0 && (cell.bits & 1u) == 0u)
        output.foreground = contrast_color(output.foreground, output.background);
    uint2 cursor = unpack_position(cursor_pos_packed);
    uint cursor_width = (flags >> CURSOR_WIDTH_SHIFT) & 7u;
    bool under_cursor = cell.grid_pos.y == cursor.y &&
        cell.grid_pos.x >= cursor.x && cell.grid_pos.x < cursor.x + cursor_width;
    if (under_cursor && (cell.bits & 2u) == 0u)
        output.foreground = load_color(unpack_color(cursor_color_packed), true);

    return output;
}

float4 cell_text_ps(CellTextVertex input) : SV_Target
{
    int3 texel = int3(int2(input.tex_coord), 0);
    bool use_linear = linear_blending();
    if (input.atlas == 1u) {
        float4 glyph = texture_1.Load(texel);
        return use_linear ? glyph : encode_premultiplied(glyph);
    }

    float4 color = use_linear ? input.foreground : encode_premultiplied(input.foreground);
    float coverage = texture_0.Load(texel).r;
    if ((flags & LINEAR_CORRECTION) != 0u) {
        float fg = luminance(color.rgb);
        float bg = luminance(input.background.rgb);
        if (abs(fg - bg) > 0.001) {
            float gamma_blend = lerp(encode_srgb(bg).r, encode_srgb(fg).r, coverage);
            coverage = saturate((linearize(gamma_blend).r - bg) / (fg - bg));
        }
    }
    return color * coverage;
}

struct ImageInput
{
    float2 grid_pos : GRID_POS;
    float2 cell_offset : CELL_OFFSET;
    float4 source_rect : SOURCE_RECT;
    float2 dest_size : DEST_SIZE;
};

struct ImageVertex
{
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD;
};

ImageVertex image_vs(uint vertex : SV_VertexID, ImageInput image)
{
    float2 corner = quad_corner(vertex);
    float2 position = cell_size * image.grid_pos + image.cell_offset + image.dest_size * corner;
    ImageVertex output;
    output.position = mul(projection_matrix, float4(position, 0.0, 1.0));
    output.tex_coord = image.source_rect.xy + image.source_rect.zw * corner;
    return output;
}

float4 sample_image(float2 uv)
{
    float4 color = texture_0.SampleLevel(image_sampler, uv, 0.0);
    if (!linear_blending()) color.rgb = encode_srgb(color.rgb);
    color.rgb *= color.a;
    return color;
}

float2 image_size()
{
    uint width, height;
    texture_0.GetDimensions(width, height);
    return float2(width, height);
}

float4 image_ps(ImageVertex input) : SV_Target
{
    return sample_image(input.tex_coord / image_size());
}

struct BgImageInput
{
    float opacity : OPACITY;
    uint info : INFO;
};

struct BgImageVertex
{
    float4 position : SV_Position;
    nointerpolation float opacity : OPACITY;
    nointerpolation uint info : INFO;
};

BgImageVertex bg_image_vs(uint vertex : SV_VertexID, BgImageInput image)
{
    BgImageVertex output;
    output.position = full_screen_vs(vertex);
    output.opacity = image.opacity;
    output.info = image.info;
    return output;
}

float4 bg_image_ps(BgImageVertex input) : SV_Target
{
    float2 size = image_size();
    float2 screen_scale = screen_size / size;
    float2 dest_size = size;
    switch ((input.info >> 4u) & 3u) {
        case 0u: dest_size = size * min(screen_scale.x, screen_scale.y); break;
        case 1u: dest_size = size * max(screen_scale.x, screen_scale.y); break;
        case 2u: dest_size = screen_size; break;
    }
    uint anchor = input.info & 15u;
    float2 offset = (screen_size - dest_size) * float2(anchor % 3u, anchor / 3u) * 0.5;
    float2 uv = (input.position.xy - offset) / dest_size;
    if ((input.info & 64u) != 0u) uv = frac(uv);

    float4 image = 0;
    if (all(uv >= 0.0) && all(uv <= 1.0)) image = sample_image(uv);
    float4 background = unpack_color(background_packed);
    if (linear_blending()) background.rgb = linearize(background.rgb);
    if (background.a <= 0.0) return 0;
    image *= min(input.opacity, 1.0 / background.a);
    return (image + float4(background.rgb, 1.0) * max(0.0, 1.0 - image.a)) * background.a;
}
