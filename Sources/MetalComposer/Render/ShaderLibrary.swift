import Foundation

/// MSL sources. Compiled at runtime so the package needs no Metal build step.
enum ShaderLibrary {
    static let builtin = """
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

    struct ParticleInstance { float2 position; float z; float size; float alpha; };
    struct ParticleUniforms { float4x4 modelView; float4x4 projection; float4 color; int hasTexture; };
    struct ParticleOut { float4 position [[position]]; float2 uv; float alpha; };

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
        o.alpha = p.alpha;
        return o;
    }

    fragment float4 particle_fragment(ParticleOut in [[stage_in]], constant ParticleUniforms& u [[buffer(0)]],
                                      texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
        float4 c = u.color;
        c.a *= in.alpha;
        if (u.hasTexture) c *= tex.sample(smp, in.uv);
        else c.a *= smoothstep(0.5, 0.0, length(in.uv - 0.5));
        return c;
    }
    """

    /// Prepended to user shaders. User code must define `mainImage`.
    static let userPrelude = """
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

    static let userPostlude = """

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

    static func wrapUserShader(_ source: String) -> String {
        userPrelude + "#line 1\n" + source + "\n" + userPostlude
    }

    static let defaultUserShader = """
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
