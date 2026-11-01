@vs vs
layout(binding=0) uniform vs_params {
    vec4 transformX;
    vec4 transformY;
    vec4 textureVec;
};

in vec2 vertex_position; // 世界坐标中的固定变换中心
in float vertex_layer; // 纹理数组的层级
in float vertex_radian; // 旋转的弧度
in vec2 vertex_scale; // 缩放后的绘制尺寸
in vec2 vertex_pivot; // 缩放和旋转共用的中心，归一化坐标
in vec4 vertex_texture; // 纹理坐标，xy是偏移量，zw是缩放
in vec4 vertex_color; // 乘色
in vec4 vertex_add_color; // 加色

out vec4 color;
out vec4 add_color;
out vec3 uvw;

void main() {
    // 顶点
    vec2 corner = vec2(gl_VertexIndex & 1, gl_VertexIndex >> 1 & 1);

    // 以固定中心为原点生成四角，再应用绘制尺寸。
    vec2 scaled = (corner - vertex_pivot) * vertex_scale;
    // 再应用旋转
    float cosA = cos(vertex_radian);
    float sinA = sin(vertex_radian);
    vec2 rotated = mat2(cosA, sinA, -sinA, cosA) * scaled;
    // 最后平移到固定中心，缩放和旋转都不会移动这个中心。
    vec3 point = vec3(rotated + vertex_position, 1);
    float clipX = dot(transformX.xyz, point);
    float clipY = dot(transformY.xyz, point);
    gl_Position = vec4(clipX, clipY, 0, 1);

    // 纹理
    color = vertex_color;
    add_color = vertex_add_color;
    vec2 uv = vertex_texture.xy + corner * vertex_texture.zw;
    uvw = vec3(uv * textureVec.xy, vertex_layer);
}
@end

@fs fs

layout(binding=0) uniform texture2DArray tex;
layout(binding=0) uniform sampler smp;

in vec4 color;
in vec4 add_color;
in vec3 uvw;
out vec4 frag_color;

void main() {
     frag_color = texture(sampler2DArray(tex, smp), uvw) * color + add_color;
}
@end

@fs msdf_fs

layout(binding=0) uniform texture2DArray tex;
layout(binding=0) uniform sampler smp;

in vec4 color;
in vec4 add_color;
in vec3 uvw;
out vec4 frag_color;

float median(float red, float green, float blue) {
    return max(min(red, green), min(max(red, green), blue));
}

void main() {
    vec3 value = texture(sampler2DArray(tex, smp), uvw).rgb;
    float distance = median(value.r, value.g, value.b) - 0.5;
    vec2 unitRange = vec2(2.0) /
        vec2(textureSize(sampler2DArray(tex, smp), 0).xy);
    vec2 screenSize = vec2(1.0) / fwidth(uvw.xy);
    float screenRange = max(0.5 * dot(unitRange, screenSize), 1.0);
    float opacity = clamp(distance * screenRange + 0.5, 0.0, 1.0);
    // 先生成字形覆盖率，再应用乘色和加色。
    frag_color = vec4(vec3(1.0), opacity) * color + add_color;
}
@end

@program quad vs fs
@program msdf vs msdf_fs
