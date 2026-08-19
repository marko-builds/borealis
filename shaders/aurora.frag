// Spike shader: animated gradient proving ShaderEffect + qsb inside an
// Omarchy overlay. Replaced by the real aurora port once the spike passes.
#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;
};

void main() {
    vec2 uv = qt_TexCoord0;
    vec3 night = vec3(0.043, 0.055, 0.082);
    vec3 cyan  = vec3(0.373, 0.808, 0.859);
    vec3 amber = vec3(0.851, 0.604, 0.369);

    float band = 0.5 + 0.5 * sin(6.28318 * (uv.x * 0.8 + time * 0.05) + uv.y * 4.0);
    float veil = smoothstep(0.85, 0.15, uv.y);
    vec3 col = night + cyan * band * veil * 0.6;
    col += amber * (0.5 + 0.5 * sin(time * 0.3 + uv.x * 2.0)) * (1.0 - veil) * 0.08;

    fragColor = vec4(col, 1.0) * qt_Opacity;
}
