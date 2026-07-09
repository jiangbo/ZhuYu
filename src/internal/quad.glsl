@vs vs
layout(binding=0) uniform vs_params {
    vec4 transformX;
    vec4 transformY;
    vec4 textureVec;
};

in vec2 vertex_position; // X Y 像素坐标
in float vertex_layer; // 纹理数组的层级
in float vertex_radian; // 旋转的弧度
in vec2 vertex_scale; // 缩放，像素尺寸
in vec2 vertex_pivot; // 旋转中心，归一化坐标
in vec4 vertex_texture; // 纹理坐标，xy是偏移量，zw是缩放
in vec4 vertex_color; // 颜色

out vec4 color;
out vec3 uvw;

void main() {
    // 顶点
    vec2 corner = vec2(gl_VertexIndex & 1, gl_VertexIndex >> 1 & 1);

    // 先缩放，缩放必须要在旋转之前做
    vec2 scaledCorner = corner * vertex_scale;
    vec2 scaledPivot  = vertex_pivot * vertex_scale;
    vec2 scaled = scaledCorner - scaledPivot;
    // 再应用旋转
    float cosA = cos(vertex_radian);
    float sinA = sin(vertex_radian);
    vec2 rotated = mat2(cosA, sinA, -sinA, cosA) * scaled;
    // 最后平移到世界坐标
    vec3 point = vec3(rotated + scaledPivot + vertex_position.xy, 1);
    float clipX = dot(transformX.xyz, point);
    float clipY = dot(transformY.xyz, point);
    gl_Position = vec4(clipX, clipY, 0, 1);

    // 纹理
    color = vertex_color;
    vec2 uv = vertex_texture.xy + corner * vertex_texture.zw;
    uvw = vec3(uv * textureVec.xy, vertex_layer);
}
@end

@fs fs

layout(binding=0) uniform texture2DArray tex;
layout(binding=0) uniform sampler smp;

in vec4 color;
in vec3 uvw;
out vec4 frag_color;

void main() {
     frag_color = texture(sampler2DArray(tex, smp), uvw) * color;
}
@end

@program quad vs fs
