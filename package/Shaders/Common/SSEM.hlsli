#ifndef __SSEM_HLSL__
#define __SSEM_HLSL__

// Screen-space extrusion mapping: pack view-space parallax offset with duv for a correct 3D segment test in composite.

namespace SSEM
{
	static float2 OctWrap(float2 v)
	{
		return (1.0 - abs(v.yx)) * (step(0.0, v.xy) * 2.0 - 1.0);
	}

	float2 OctEncode(float3 n)
	{
		n /= (abs(n.x) + abs(n.y) + abs(n.z));
		float2 o = n.xy;
		if (n.z < 0.0)
			o = OctWrap(o);
		return o;
	}

	float3 OctDecode(float2 f)
	{
		float3 n = float3(f.xy, 1.0 - abs(f.x) - abs(f.y));
		if (n.z < 0.0)
			n.xy = OctWrap(n.xy);
		return normalize(n);
	}

	// .xy = duv, .z = bitcast of two fp16 oct coords, .w = |offsetVS| (view units)
	float4 PackDuvViewOffset(float2 duv, float3 offsetVS)
	{
		float len = length(offsetVS);
		if (len < 1e-10)
			return float4(duv.xy, asfloat(0u), 0.0);
		float3 dir = offsetVS / len;
		float2 oct = OctEncode(dir);
		uint u = (uint)f32tof16(oct.x) | ((uint)f32tof16(oct.y) << 16);
		return float4(duv.xy, asfloat(u), len);
	}

	void UnpackDuvViewOffset(float4 packed, out float2 duv, out float3 offsetVS)
	{
		duv = packed.xy;
		float len = packed.w;
		if (len < 1e-10) {
			offsetVS = 0;
			return;
		}
		uint u = asuint(packed.z);
		float2 oct = float2(f16tof32(u & 0xFFFFu), f16tof32(u >> 16));
		offsetVS = OctDecode(oct) * len;
	}

	float3 UnpackViewOffset(float4 packed)
	{
		float2 duv;
		float3 offsetVS;
		UnpackDuvViewOffset(packed, duv, offsetVS);
		return offsetVS;
	}
}

#endif
