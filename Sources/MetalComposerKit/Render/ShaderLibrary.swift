import Foundation

/// MSL sources. Compiled at runtime so the package needs no Metal build step.
package enum ShaderLibrary {
    package static let builtin = """
    #include <metal_stdlib>
    using namespace metal;

    struct FSOut { float4 position [[position]]; float2 uv; };

    vertex FSOut fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        FSOut o;
        o.position = float4(p * 2.0 - 1.0, 1.0, 1.0); // far plane, so Clear resets depth
        o.uv = p;
        return o;
    }

    fragment float4 clear_fragment(FSOut in [[stage_in]], constant float4& color [[buffer(0)]]) {
        return color;
    }

    // Sprite and Billboard: the four corners arrive already in clip space (computed on the CPU),
    // so perspective-correct texturing comes from the rasterizer.
    struct QuadUniforms { float4 corners[4]; float4 color; int hasTexture; };
    struct SpriteOut { float4 position [[position]]; float2 uv; };

    vertex SpriteOut sprite_vertex(uint vid [[vertex_id]], constant QuadUniforms& u [[buffer(0)]]) {
        const float2 uvs[4] = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };
        SpriteOut o;
        o.position = u.corners[vid];
        o.uv = uvs[vid];
        return o;
    }

    fragment float4 sprite_fragment(SpriteOut in [[stage_in]], constant QuadUniforms& u [[buffer(0)]],
                                    texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
        float4 c = u.color;
        if (u.hasTexture) c *= tex.sample(smp, in.uv);
        if (c.a < 0.004) discard_fragment(); // keep transparent texels out of the depth buffer
        return c;
    }

    // Text Image: glyph images from the atlas (coverage in red) placed in pixel coordinates.
    struct GlyphInstance { float4 destination; float4 source; }; // x, y (top-left), width, height
    struct GlyphOut { float4 position [[position]]; float2 uv; };

    vertex GlyphOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device GlyphInstance* glyphs [[buffer(0)]],
                                 constant float4& sizes [[buffer(1)]]) { // target width/height, atlas width/height
        float2 corner = float2(vid & 1, vid >> 1);
        GlyphInstance g = glyphs[iid];
        float2 p = g.destination.xy + corner * g.destination.zw;
        GlyphOut o;
        o.position = float4(p.x / sizes.x * 2.0 - 1.0, 1.0 - p.y / sizes.y * 2.0, 0.0, 1.0);
        o.uv = (g.source.xy + corner * g.source.zw) / sizes.zw;
        return o;
    }

    fragment float4 glyph_fragment(GlyphOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(filter::nearest);
        return float4(1.0, 1.0, 1.0, atlas.sample(s, in.uv).r);
    }

    // Image Importer presets: white shapes drawn from signed distances (negative inside), with an
    // optional glow around them. The shape spans -1…1 and shrinks to leave room for the glow.
    struct PresetUniforms { int shape; float thickness; float glow; float glowIntensity; float pixels; };

    static float sd_box(float2 p, float2 b) {
        float2 d = abs(p) - b;
        return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
    }
    static float sd_triangle(float2 p) { // equilateral, pointing up, centered in -1…1
        p.y += 0.25;
        const float k = sqrt(3.0), r = 0.866;
        p.x = abs(p.x) - r;
        p.y = p.y + r / k;
        if (p.x + k * p.y > 0.0) p = float2(p.x - k * p.y, -k * p.x - p.y) / 2.0;
        p.x -= clamp(p.x, -2.0 * r, 0.0);
        return -length(p) * sign(p.y);
    }
    static float sd_star(float2 p, float rf) { // five points, inner radius rf
        const float2 k1 = float2(0.809016994375, -0.587785252292);
        const float2 k2 = float2(-k1.x, k1.y);
        p.x = abs(p.x);
        p -= 2.0 * max(dot(k1, p), 0.0) * k1;
        p -= 2.0 * max(dot(k2, p), 0.0) * k2;
        p.x = abs(p.x);
        p.y -= 1.0;
        float2 ba = rf * float2(-k1.y, k1.x) - float2(0.0, 1.0);
        float h = clamp(dot(p, ba) / dot(ba, ba), 0.0, 1.0);
        return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
    }

    fragment float4 preset_fragment(FSOut in [[stage_in]], constant PresetUniforms& u [[buffer(0)]]) {
        float scale = 1.0 + u.glow;
        float2 p = (in.uv * 2.0 - 1.0) * scale;
        float t = u.thickness;
        float d;
        switch (u.shape) {
            case 1: d = length(p) - 1.0; break;                                    // Circle
            case 2: d = abs(length(p) - (1.0 - t * 0.5)) - t * 0.5; break;         // Ring
            case 3: return float4(1.0, 1.0, 1.0, pow(saturate(1.0 - length(p)), 2.0)); // Soft Dot
            case 4: d = sd_box(p, float2(1.0)); break;                             // Square
            case 5: d = abs(sd_box(p, float2(1.0 - t * 0.5))) - t * 0.5; break;   // Frame
            case 6: d = sd_triangle(p); break;                                     // Triangle
            case 7: d = sd_star(p + float2(0.0, 0.095), 0.45); break;              // Star (centered top to bottom)
            case 8: d = min(sd_box(p, float2(1.0, t * 0.5)), sd_box(p, float2(t * 0.5, 1.0))); break; // Cross
            default: d = sd_box(p, float2(1.0, t * 0.5)); break;                   // Line
        }
        // Antialiased edge one pixel wide; the glow fades from the edge out to `glow` (shape units).
        float pixel = 2.0 * scale / u.pixels;
        float alpha = saturate(0.5 - d / pixel);
        if (u.glow > 0.0) {
            float g = saturate(1.0 - max(d, 0.0) / u.glow);
            alpha = max(alpha, u.glowIntensity * g * g * g);
        }
        return float4(1.0, 1.0, 1.0, alpha);
    }

    // Triangle meshes (Cylinder): model-space vertices, shaded like sprites (sprite_fragment reads
    // the color and texture flag from a QuadUniforms whose corners are unused).
    struct MeshVertex { float4 position; float2 uv; };

    vertex SpriteOut mesh_vertex(uint vid [[vertex_id]], const device MeshVertex* vertices [[buffer(1)]],
                                 constant float4x4& mvp [[buffer(2)]]) {
        SpriteOut o;
        o.position = mvp * vertices[vid].position;
        o.uv = vertices[vid].uv;
        return o;
    }

    struct ParticleInstance { float2 position; float z; float size; float alpha; float4 color; };
    struct ParticleUniforms { float4x4 modelView; float4x4 projection; int hasTexture; };
    struct ParticleOut { float4 position [[position]]; float2 uv; float4 color; };

    // Particles are camera-facing: the quad is expanded in view space after the model transform.
    vertex ParticleOut particle_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                       constant ParticleUniforms& u [[buffer(0)]],
                                       const device ParticleInstance* instances [[buffer(1)]]) {
        const float2 corners[4] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(-0.5, 0.5), float2(0.5, 0.5) };
        ParticleInstance p = instances[iid];
        float4 center = u.modelView * float4(p.position, p.z, 1.0);
        ParticleOut o;
        o.position = u.projection * float4(center.xy + corners[vid] * p.size, center.z, 1.0);
        o.uv = float2(corners[vid].x + 0.5, 0.5 - corners[vid].y);
        o.color = float4(p.color.rgb, p.color.a * p.alpha);
        return o;
    }

    fragment float4 particle_fragment(ParticleOut in [[stage_in]], constant ParticleUniforms& u [[buffer(0)]],
                                      texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
        float4 c = in.color;
        if (u.hasTexture) c *= tex.sample(smp, in.uv);
        else c.a *= smoothstep(0.5, 0.0, length(in.uv - 0.5));
        return c;
    }
    """

    /// Prepended to user shaders. User code must define `mainImage`.
    package static let userPrelude = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float time;         // seconds
        float2 resolution;  // pixels
        float2 mouse;       // 0…1, origin bottom-left
        float4 color;       // Color input
        float4 params;      // Param 1…4
    };

    // Samples the Image input with a bottom-left uv origin.
    static inline float4 sampleImage(texture2d<float> image, sampler s, float2 uv) {
        return image.sample(s, float2(uv.x, 1.0 - uv.y));
    }

    """

    package static let userPostlude = """

    struct MCOut { float4 position [[position]]; float2 uv; };

    vertex MCOut mc_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        MCOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = p;
        return o;
    }

    fragment float4 mc_fragment(MCOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                texture2d<float> image [[texture(0)]], sampler s [[sampler(0)]]) {
        return mainImage(in.uv, u, image, s);
    }
    """

    package static func wrapUserShader(_ source: String) -> String {
        userPrelude + "#line 1\n" + source + "\n" + userPostlude
    }

    package static let defaultUserShader = """
    // uv: 0…1 (bottom-left origin). Return premultiplied-free RGBA.
    // Available: u.time, u.resolution, u.mouse, u.color, u.params (Param 1…4)
    //            sampleImage(image, s, uv) reads the Image input.
    float4 mainImage(float2 uv, constant Uniforms& u, texture2d<float> image, sampler s) {
        float2 p = (uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0) * 3.0;
        float t = u.time * (0.4 + u.params.x);
        float v = sin(p.x + t) + sin(p.y * 1.3 - t * 1.1) + sin(length(p) * 2.0 - t * 1.7)
                + sin(length(p - (u.mouse - 0.5) * 3.0) * 3.0 - t * 2.0);
        float3 col = 0.5 + 0.5 * cos(v + float3(0.0, 2.0, 4.0) + u.params.y * 6.2831);
        return float4(col * u.color.rgb * 0.55, u.color.a);
    }
    """
}
