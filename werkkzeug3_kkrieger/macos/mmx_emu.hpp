// This file is distributed under a BSD license. See LICENSE.txt for details.

// Exact scalar emulation of the MMX instructions/intrinsics used by the
// texture generator. Only what the code needs, with the same lane order,
// wrap-around and saturation rules as the hardware, so results stay bit
// identical to the original x86 player.

#ifndef __MMX_EMU_HPP__
#define __MMX_EMU_HPP__

#include "_types.hpp"

union m64
{
  sU64 q;
  sS16 w[4];
  sU16 uw[4];
  sS32 d[2];
  sU32 ud[2];
};

static __forceinline m64 m64q(sU64 v)            { m64 r; r.q = v; return r; }
static __forceinline m64 m64ld(const void *p)    { m64 r; memcpy(&r,p,8); return r; }
static __forceinline void m64st(void *p,m64 a)   { memcpy(p,&a,8); }

static __forceinline sS16 m64ssw(sS32 v)         { return v>32767 ? 32767 : v<-32768 ? -32768 : (sS16)v; }
static __forceinline sU16 m64usw(sS32 v)         { return v>65535 ? 65535 : v<0 ? 0 : (sU16)v; }

#define MMX_W(expr) { m64 r; for(sInt i=0;i<4;i++) r.w[i] = (expr); return r; }
#define MMX_UW(expr) { m64 r; for(sInt i=0;i<4;i++) r.uw[i] = (expr); return r; }
#define MMX_D(expr) { m64 r; for(sInt i=0;i<2;i++) r.d[i] = (expr); return r; }

// 16 bit arithmetic
static __forceinline m64 paddw(m64 a,m64 b)    MMX_UW(a.uw[i]+b.uw[i])
static __forceinline m64 psubw(m64 a,m64 b)    MMX_UW(a.uw[i]-b.uw[i])
static __forceinline m64 paddsw(m64 a,m64 b)   MMX_W(m64ssw(a.w[i]+b.w[i]))
static __forceinline m64 psubsw(m64 a,m64 b)   MMX_W(m64ssw(a.w[i]-b.w[i]))
static __forceinline m64 paddusw(m64 a,m64 b)  MMX_UW(m64usw(a.uw[i]+b.uw[i]))
static __forceinline m64 psubusw(m64 a,m64 b)  MMX_UW(m64usw(a.uw[i]-b.uw[i]))
static __forceinline m64 pmullw(m64 a,m64 b)   MMX_UW((sU16)(a.w[i]*b.w[i]))
static __forceinline m64 pmulhw(m64 a,m64 b)   MMX_UW((sU16)((a.w[i]*b.w[i])>>16))
static __forceinline m64 pmulhuw(m64 a,m64 b)  MMX_UW((sU16)(((sU32)a.uw[i]*b.uw[i])>>16))
static __forceinline m64 pmaxsw(m64 a,m64 b)   MMX_W(a.w[i]>b.w[i] ? a.w[i] : b.w[i])
static __forceinline m64 pcmpgtw(m64 a,m64 b)  MMX_UW(a.w[i]>b.w[i] ? 0xffff : 0)

// 16 bit shifts (count>15 gives 0 / sign fill)
static __forceinline m64 psllw(m64 a,sInt n)   MMX_UW(n>15 ? 0 : (sU16)(a.uw[i]<<n))
static __forceinline m64 psrlw(m64 a,sInt n)   MMX_UW(n>15 ? 0 : (sU16)(a.uw[i]>>n))
static __forceinline m64 psraw(m64 a,sInt n)   MMX_W((sS16)(a.w[i]>>(n>15 ? 15 : n)))

// 32 bit
static __forceinline m64 paddd(m64 a,m64 b)    MMX_D((sS32)(a.ud[i]+b.ud[i]))
static __forceinline m64 psubd(m64 a,m64 b)    MMX_D((sS32)(a.ud[i]-b.ud[i]))
static __forceinline m64 pslld(m64 a,sInt n)   MMX_D(n>31 ? 0 : (sS32)(a.ud[i]<<n))
static __forceinline m64 psrld(m64 a,sInt n)   MMX_D(n>31 ? 0 : (sS32)(a.ud[i]>>n))
static __forceinline m64 psrad(m64 a,sInt n)   MMX_D(a.d[i]>>(n>31 ? 31 : n))
static __forceinline m64 pcmpgtd(m64 a,m64 b)  MMX_D(a.d[i]>b.d[i] ? -1 : 0)
static __forceinline m64 pmaddwd(m64 a,m64 b)
{
  m64 r;
  r.ud[0] = (sU32)(a.w[0]*b.w[0]) + (sU32)(a.w[1]*b.w[1]);
  r.ud[1] = (sU32)(a.w[2]*b.w[2]) + (sU32)(a.w[3]*b.w[3]);
  return r;
}

// 64 bit / logic
static __forceinline m64 pand(m64 a,m64 b)     { return m64q(a.q & b.q); }
static __forceinline m64 por(m64 a,m64 b)      { return m64q(a.q | b.q); }
static __forceinline m64 pxor(m64 a,m64 b)     { return m64q(a.q ^ b.q); }
static __forceinline m64 psllq(m64 a,sInt n)   { return m64q(n>63 ? 0 : a.q<<n); }
static __forceinline m64 psrlq(m64 a,sInt n)   { return m64q(n>63 ? 0 : a.q>>n); }
static __forceinline m64 movd(sU32 v)          { return m64q(v); }

// pack / unpack
static __forceinline m64 packssdw(m64 a,m64 b)
{
  m64 r;
  r.w[0] = m64ssw(a.d[0]); r.w[1] = m64ssw(a.d[1]);
  r.w[2] = m64ssw(b.d[0]); r.w[3] = m64ssw(b.d[1]);
  return r;
}
static __forceinline m64 punpcklwd(m64 a,m64 b)
{
  m64 r; r.uw[0]=a.uw[0]; r.uw[1]=b.uw[0]; r.uw[2]=a.uw[1]; r.uw[3]=b.uw[1]; return r;
}
static __forceinline m64 punpckhwd(m64 a,m64 b)
{
  m64 r; r.uw[0]=a.uw[2]; r.uw[1]=b.uw[2]; r.uw[2]=a.uw[3]; r.uw[3]=b.uw[3]; return r;
}
static __forceinline m64 punpckldq(m64 a,m64 b)
{
  m64 r; r.ud[0]=a.ud[0]; r.ud[1]=b.ud[0]; return r;
}

#undef MMX_W
#undef MMX_UW
#undef MMX_D

// intrinsic names used by Bitmap_Blur

typedef m64 __m64;

static __forceinline m64 _mm_set_pi16(sInt e3,sInt e2,sInt e1,sInt e0)
{
  m64 r; r.uw[0]=(sU16)e0; r.uw[1]=(sU16)e1; r.uw[2]=(sU16)e2; r.uw[3]=(sU16)e3; return r;
}
static __forceinline m64 _mm_set_pi32(sInt e1,sInt e0)       { m64 r; r.d[0]=e0; r.d[1]=e1; return r; }
#define _mm_madd_pi16     pmaddwd
#define _mm_unpacklo_pi16 punpcklwd
#define _mm_unpackhi_pi16 punpckhwd
#define _mm_add_pi32      paddd
#define _mm_sub_pi32      psubd
#define _mm_packs_pi32    packssdw
#define _mm_adds_pu16     paddusw
#define _mm_srli_pi32     psrld
#define _mm_srai_pi32     psrad
#define _mm_slli_pi32     pslld
#define _mm_srli_pi16     psrlw
#define _mm_mullo_pi16    pmullw
#define _mm_mulhi_pu16    pmulhuw
#define _mm_cmpgt_pi32    pcmpgtd
#define _mm_subs_pi16     psubsw
#define _mm_add_pi16      paddw
static __forceinline void _mm_empty() {}

#endif
