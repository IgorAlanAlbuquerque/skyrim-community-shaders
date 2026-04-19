// SSDM: downsample per-pixel displacement (duv) to coarser mips by averaging 2×2 finer texels.
// SrcDuv is bound as a single-mip SRV (the source mip). Load(..., 0) uses mip 0 of that view.

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
	float4 v00 = SrcDuv.Load(int3(base + int2(0, 0), 0));
	float4 v10 = SrcDuv.Load(int3(base + int2(1, 0), 0));
	float4 v01 = SrcDuv.Load(int3(base + int2(0, 1), 0));
	float4 v11 = SrcDuv.Load(int3(base + int2(1, 1), 0));
	// Average duv only from children with forward SSDM coverage. Plain mean blends
	// foreground duv with background (0) at silhouettes → bogus coarse vectors and noisy negative space.
	static const float kCovGate = 0.5;
	float w00 = v00.z > kCovGate ? 1.0 : 0.0;
	float w10 = v10.z > kCovGate ? 1.0 : 0.0;
	float w01 = v01.z > kCovGate ? 1.0 : 0.0;
	float w11 = v11.z > kCovGate ? 1.0 : 0.0;
	float wsum = w00 + w10 + w01 + w11;
	float2 duvAvg = wsum > 0.0 ? (v00.xy * w00 + v10.xy * w10 + v01.xy * w01 + v11.xy * w11) / wsum : float2(0, 0);
	float cov = max(max(v00.z, v10.z), max(v01.z, v11.z));
	DstDuv[dtid.xy] = float4(duvAvg, cov, 0.0);
}
