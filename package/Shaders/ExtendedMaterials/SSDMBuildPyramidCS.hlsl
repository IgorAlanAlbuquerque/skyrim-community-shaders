// SSDM: downsample per-pixel displacement (duv) to coarser mips by averaging 2×2 finer texels.

cbuffer SSDMBuildCB : register(b0)
{
	int SrcMip;
	int3 Pad;
};

Texture2D<float2> SrcDuv : register(t0);
RWTexture2D<float2> DstDuv : register(u0);

[numthreads(8, 8, 1)]
void main(uint3 dtid : SV_DispatchThreadID)
{
	uint2 dstDim;
	DstDuv.GetDimensions(dstDim.x, dstDim.y);
	if (any(dtid.xy >= dstDim))
		return;

	int2 base = int2(dtid.xy) * 2;
	float2 v00 = SrcDuv.Load(int3(base + int2(0, 0), SrcMip));
	float2 v10 = SrcDuv.Load(int3(base + int2(1, 0), SrcMip));
	float2 v01 = SrcDuv.Load(int3(base + int2(0, 1), SrcMip));
	float2 v11 = SrcDuv.Load(int3(base + int2(1, 1), SrcMip));
	DstDuv[dtid.xy] = (v00 + v10 + v01 + v11) * 0.25;
}
