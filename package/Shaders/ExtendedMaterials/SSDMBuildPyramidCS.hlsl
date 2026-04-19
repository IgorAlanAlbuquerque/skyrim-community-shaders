// SSDM: downsample per-pixel displacement (duv) to coarser mips by averaging 2×2 finer texels.

cbuffer SSDMBuildCB : register(b0)
{
	int SrcMip;
	int3 Pad;
};

Texture2D<float4> SrcDuv : register(t0);
RWTexture2D<float4> DstDuv : register(u0);

[numthreads(8, 8, 1)]
void main(uint3 dtid : SV_DispatchThreadID)
{
	uint2 dstDim;
	DstDuv.GetDimensions(dstDim.x, dstDim.y);
	if (any(dtid.xy >= dstDim))
		return;

	int2 base = int2(dtid.xy) * 2;
	float4 v00 = SrcDuv.Load(int3(base + int2(0, 0), SrcMip));
	float4 v10 = SrcDuv.Load(int3(base + int2(1, 0), SrcMip));
	float4 v01 = SrcDuv.Load(int3(base + int2(0, 1), SrcMip));
	float4 v11 = SrcDuv.Load(int3(base + int2(1, 1), SrcMip));
	// Average duv only; coarser mips do not preserve a meaningful oct+length average (composite reads mip0 .zw only).
	float2 duvAvg = (v00.xy + v10.xy + v01.xy + v11.xy) * 0.25;
	DstDuv[dtid.xy] = float4(duvAvg, v00.zw);
}
