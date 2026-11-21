// This file is distributed under a BSD license. See LICENSE.txt for details.

// Translates Direct3D 9 shader bytecode (vs_1_1 + ps_1_x, the subset that the
// kkrieger materials generate) into one Metal Shading Language source with a
// vertex function "vsmain" and a fragment function "psmain".

#include "d3d9_msl.hpp"
#include <stdio.h>
#include <string.h>
#include <stdarg.h>

namespace {

enum
{
  OP_NOP=0, OP_MOV, OP_ADD, OP_SUB, OP_MAD, OP_MUL, OP_RCP, OP_RSQ, OP_DP3, OP_DP4,
  OP_MIN, OP_MAX, OP_SLT, OP_SGE, OP_EXP, OP_LOG, OP_LIT, OP_DST, OP_LRP, OP_FRC,
  OP_M4x4, OP_M4x3, OP_M3x4, OP_M3x3, OP_M3x2,
  OP_DCL=31, OP_ABS=35, OP_TEXCOORD=64, OP_TEXKILL=65, OP_TEX=66,
  OP_EXPP=78, OP_LOGP=79, OP_CND=80, OP_DEF=81, OP_CMP=88,
  OP_PHASE=0xfffd, OP_COMMENT=0xfffe, OP_END=0xffff,
};

enum
{
  REG_TEMP=0, REG_INPUT=1, REG_CONST=2, REG_TEXTURE=3, REG_RASTOUT=4,
  REG_ATTROUT=5, REG_TEXCRDOUT=6, REG_COLOROUT=8, REG_SAMPLER=10,
};

struct Writer
{
  std::string &S;
  Writer(std::string &s) : S(s) {}
  void operator()(const char *fmt,...)
  {
    char buf[1024];
    va_list ap;
    va_start(ap,fmt);
    vsnprintf(buf,sizeof(buf),fmt,ap);
    va_end(ap);
    S += buf;
  }
};

// number of parameter tokens for shader models without length field
static int ParamCount(unsigned op,unsigned ver)
{
  switch(op)
  {
  case OP_NOP: case OP_PHASE: return 0;
  case OP_TEXKILL: return 1;
  case OP_TEXCOORD: return ver>=0x104 ? 2 : 1;
  case OP_TEX: return ver>=0x200 ? 3 : (ver>=0x104 ? 2 : 1);
  case OP_MOV: case OP_RCP: case OP_RSQ: case OP_EXP: case OP_LOG: case OP_LIT:
  case OP_FRC: case OP_DCL: case OP_ABS: case OP_EXPP: case OP_LOGP: return 2;
  case OP_ADD: case OP_SUB: case OP_MUL: case OP_DP3: case OP_DP4: case OP_MIN:
  case OP_MAX: case OP_SLT: case OP_SGE: case OP_DST:
  case OP_M4x4: case OP_M4x3: case OP_M3x4: case OP_M3x3: case OP_M3x2: return 3;
  case OP_MAD: case OP_LRP: case OP_CND: case OP_CMP: return 4;
  case OP_DEF: return 5;
  }
  return -1;
}

static unsigned RegType(unsigned t) { return ((t>>28)&7) | ((t>>8)&0x18); }
static unsigned RegNum(unsigned t)  { return t&0x7ff; }

struct Translator
{
  std::string &Out;
  std::string Err;
  Writer W;
  bool IsPS;
  unsigned Ver;
  float Def[256][4];
  bool HasDef[256];
  unsigned TexTypes;

  Translator(std::string &out) : Out(out), W(out), IsPS(false), Ver(0), TexTypes(0)
  {
    memset(HasDef,0,sizeof(HasDef));
  }

  void Fail(const char *msg,unsigned v=0)
  {
    if(Err.empty())
    {
      char buf[128];
      snprintf(buf,sizeof(buf),"%s %s (%u)",IsPS ? "ps:" : "vs:",msg,v);
      Err = buf;
    }
  }

  // register name without swizzle
  std::string Reg(unsigned t,int offset=0)
  {
    char buf[64];
    unsigned type = RegType(t), num = RegNum(t)+offset;
    switch(type)
    {
    case REG_TEMP:   snprintf(buf,sizeof(buf),"r%u",num); break;
    case REG_INPUT:  snprintf(buf,sizeof(buf),"v%u",num); break;
    case REG_CONST:
      if(num<256 && HasDef[num])
        snprintf(buf,sizeof(buf),"float4(%.9g,%.9g,%.9g,%.9g)",Def[num][0],Def[num][1],Def[num][2],Def[num][3]);
      else
        snprintf(buf,sizeof(buf),"cb[%u]",num);
      if(IsPS && Ver<0x200)                 // ps 1.x constants are clamped to [-1,1]
        return std::string("clamp(")+buf+",-1.0,1.0)";
      break;
    case REG_TEXTURE:  snprintf(buf,sizeof(buf),IsPS ? "t%u" : "a%u",num); break;
    case REG_RASTOUT:  snprintf(buf,sizeof(buf),num==0 ? "oPos" : num==1 ? "oFog" : "oPts"); break;
    case REG_ATTROUT:  snprintf(buf,sizeof(buf),"oD%u",num); break;
    case REG_TEXCRDOUT:snprintf(buf,sizeof(buf),"oT%u",num); break;
    case REG_COLOROUT: snprintf(buf,sizeof(buf),"oC%u",num); break;
    default:
      Fail("register type",type);
      snprintf(buf,sizeof(buf),"r0");
    }
    return buf;
  }

  std::string Src(unsigned t,int offset=0,bool scalarSel=false)
  {
    if(t & (1<<13)) Fail("relative addressing");
    std::string r = Reg(t,offset);
    unsigned swz = (t>>16)&0xff;
    static const char comp[] = "xyzw";
    if(scalarSel)                           // rcp/rsq: replicate swizzle, else .w
    {
      unsigned c0 = swz&3;
      bool rep = ((swz>>2)&3)==c0 && ((swz>>4)&3)==c0 && ((swz>>6)&3)==c0;
      r = r + "." + comp[rep ? c0 : (swz>>6)&3];
    }
    else if(swz!=0xe4)
    {
      r = r + "." + comp[swz&3] + comp[(swz>>2)&3] + comp[(swz>>4)&3] + comp[(swz>>6)&3];
    }
    switch((t>>24)&0xf)
    {
    case 0: break;
    case 1: r = "(-"+r+")"; break;
    case 2: r = "("+r+"-0.5)"; break;          // _bias
    case 3: r = "(-("+r+"-0.5))"; break;
    case 4: r = "("+r+"*2.0-1.0)"; break;      // _bx2
    case 5: r = "(-("+r+"*2.0-1.0))"; break;
    case 6: r = "(1.0-"+r+")"; break;          // invert
    case 7: r = "("+r+"*2.0)"; break;          // _x2 (ps 1.4)
    case 8: r = "(-("+r+"*2.0))"; break;
    case 11: r = "abs("+r+")"; break;
    case 12: r = "(-abs("+r+"))"; break;
    default: Fail("source modifier",(t>>24)&0xf);
    }
    return r;
  }

  // compute into a temporary, apply result modifiers; the masked write is separate
  void Compute(int n,unsigned op,const unsigned *p)
  {
    std::string e;
    unsigned d = p[0];
    switch(op)
    {
    case OP_MOV: e = Src(p[1]); break;
    case OP_ADD: e = Src(p[1])+"+"+Src(p[2]); break;
    case OP_SUB: e = Src(p[1])+"-"+Src(p[2]); break;
    case OP_MUL: e = Src(p[1])+"*"+Src(p[2]); break;
    case OP_MAD: e = Src(p[1])+"*"+Src(p[2])+"+"+Src(p[3]); break;
    case OP_LRP: e = "mix("+Src(p[3])+","+Src(p[2])+","+Src(p[1])+")"; break;
    case OP_DP3: e = "float4(dot(("+Src(p[1])+").xyz,("+Src(p[2])+").xyz))"; break;
    case OP_DP4: e = "float4(dot("+Src(p[1])+","+Src(p[2])+"))"; break;
    case OP_MIN: e = "min("+Src(p[1])+","+Src(p[2])+")"; break;
    case OP_MAX: e = "max("+Src(p[1])+","+Src(p[2])+")"; break;
    case OP_SLT: e = "select(float4(0.0),float4(1.0),"+Src(p[1])+"<"+Src(p[2])+")"; break;
    case OP_SGE: e = "select(float4(0.0),float4(1.0),"+Src(p[1])+">="+Src(p[2])+")"; break;
    case OP_RCP: e = "float4(1.0/"+Src(p[1],0,true)+")"; break;
    case OP_RSQ: e = "float4(rsqrt(abs("+Src(p[1],0,true)+")))"; break;
    case OP_FRC: e = "fract("+Src(p[1])+")"; break;
    case OP_ABS: e = "abs("+Src(p[1])+")"; break;
    case OP_CND: e = "select("+Src(p[3])+","+Src(p[2])+",("+Src(p[1])+")>0.5)"; break;
    case OP_CMP: e = "select("+Src(p[3])+","+Src(p[2])+",("+Src(p[1])+")>=0.0)"; break;
    case OP_M4x4: case OP_M4x3: case OP_M3x4: case OP_M3x3: case OP_M3x2:
      {
        int rows = (op==OP_M4x4||op==OP_M3x4) ? 4 : (op==OP_M4x3||op==OP_M3x3) ? 3 : 2;
        bool four = (op==OP_M4x4||op==OP_M4x3);
        e = "float4(";
        for(int i=0;i<4;i++)
        {
          if(i) e += ",";
          if(i<rows)
            e += four ? "dot("+Src(p[1])+","+Src(p[2],i)+")"
                      : "dot(("+Src(p[1])+").xyz,("+Src(p[2],i)+").xyz)";
          else
            e += "0.0";
        }
        e += ")";
      }
      break;
    default:
      Fail("opcode",op);
      e = "float4(0.0)";
    }

    W("  float4 q%d = %s;\n",n,e.c_str());
    int shift = (d>>24)&0xf;
    if(shift)
    {
      static const char *scale[16] = { 0,"2.0","4.0","8.0",0,0,0,0,0,0,0,0,0,"0.125","0.25","0.5" };
      if(!scale[shift]) Fail("shift",shift);
      else W("  q%d *= %s;\n",n,scale[shift]);
    }
    if((d>>20)&1)
      W("  q%d = saturate(q%d);\n",n,n);
    else if(IsPS && Ver<0x104 && RegType(d)!=REG_COLOROUT)
      W("  q%d = clamp(q%d,-1.0,1.0);\n",n,n);     // ps 1.1-1.3 register range
  }

  void Store(int n,unsigned d)
  {
    unsigned mask = (d>>16)&0xf;
    std::string r = Reg(d);
    if(mask==0xf || mask==0)
      W("  %s = q%d;\n",r.c_str(),n);
    else
    {
      char m[5]; int k=0;
      for(int i=0;i<4;i++) if(mask&(1<<i)) m[k++] = "xyzw"[i];
      m[k] = 0;
      W("  %s.%s = q%d.%s;\n",r.c_str(),m,n,m);
    }
  }

  // walk the code. callback for each instruction: op, params, count, coissue
  template <class F> bool Walk(const unsigned *code,F f)
  {
    unsigned ver = code[0]&0xffff;
    const unsigned *p = code+1;
    for(int guard=0;guard<100000;guard++)
    {
      unsigned t = *p;
      unsigned op = t&0xffff;
      if(t==OP_END) return true;
      if(op==OP_COMMENT) { p += 1+((t>>16)&0x7fff); continue; }
      int n = ver>=0x200 ? (int)((t>>24)&15) : ParamCount(op,ver);
      if(n<0) { Fail("unknown opcode",op); return false; }
      f(op,p+1,n,(t>>30)&1);
      p += 1+n;
    }
    Fail("no end token");
    return false;
  }

  void CollectDefs(const unsigned *code)
  {
    memset(HasDef,0,sizeof(HasDef));
    Walk(code,[&](unsigned op,const unsigned *p,int n,bool co)
    {
      if(op==OP_DEF && RegNum(p[0])<256)
      {
        unsigned r = RegNum(p[0]);
        memcpy(Def[r],p+1,16);
        HasDef[r] = true;
      }
    });
  }

  // emit the instruction body; pairs of co-issued instructions read their
  // sources before either of them writes
  void Body(const unsigned *code)
  {
    int n = 0;
    struct Pending { int q; unsigned d; } pending[2];
    int npending = 0;
    std::vector<std::pair<unsigned,const unsigned *>> list;
    std::vector<bool> coissue;
    Walk(code,[&](unsigned op,const unsigned *p,int cnt,bool co)
    {
      if(op==OP_DEF || op==OP_DCL || op==OP_NOP || op==OP_PHASE) return;
      list.push_back(std::make_pair(op,p));
      coissue.push_back(co);
    });
    for(size_t i=0;i<list.size();i++)
    {
      unsigned op = list[i].first;
      const unsigned *p = list[i].second;
      if(op==OP_TEX)
      {
        Tex(p);
        continue;
      }
      if(op==OP_TEXKILL)
      {
        W("  if(any((%s).xyz<0.0)) discard_fragment();\n",Reg(p[0]).c_str());
        continue;
      }
      if(op==OP_TEXCOORD)
      {
        unsigned r = RegNum(p[0]);
        W("  t%u = saturate(float4(fin.t%u.xyz,1.0));\n",r,r);
        continue;
      }
      Compute(n,op,p);
      pending[npending].q = n; pending[npending].d = p[0]; npending++; n++;
      bool nextCo = (i+1<list.size()) && coissue[i+1];
      if(!nextCo || npending==2)
      {
        for(int k=0;k<npending;k++) Store(pending[k].q,pending[k].d);
        npending = 0;
      }
    }
  }

  void Tex(const unsigned *p)
  {
    if(Ver>=0x104) { Fail("ps 1.4/2.0 texld"); return; }
    unsigned r = RegNum(p[0]);
    unsigned type = (TexTypes>>(r*2))&3;
    W("  t%u = tex%u.sample(smp%u,fin.t%u.%s);\n",r,r,r,r,type==D3D9MSL_TEX2D ? "xy" : "xyz");
  }
};

static const char *UsageName(unsigned usage,unsigned index,int &slot)
{
  // attribute slots, see D3D9MSL_ATTR_*
  switch(usage)
  {
  case 0:  slot = D3D9MSL_ATTR_POSITION; return "pos";
  case 3:  slot = D3D9MSL_ATTR_NORMAL; return "normal";
  case 10: slot = index ? D3D9MSL_ATTR_COLOR1 : D3D9MSL_ATTR_COLOR0; return index ? "color1" : "color0";
  case 5:  slot = index<4 ? D3D9MSL_ATTR_TEXCOORD0+index : -1; return "tex";
  case 6:  slot = D3D9MSL_ATTR_TANGENT; return "tangent";
  case 7:  slot = D3D9MSL_ATTR_BINORMAL; return "binormal";
  }
  slot = -1;
  return 0;
}

} // namespace

/****************************************************************************/

bool D3D9ToMSL(const unsigned *vs,const unsigned *ps,unsigned texTypes,
               unsigned attribMask,std::string &out,std::string &error)
{
  out.clear();
  error.clear();
  if(!vs || !ps || (vs[0]&0xffff0000)!=0xfffe0000 || (ps[0]&0xffff0000)!=0xffff0000)
  {
    error = "need a vertex and a pixel shader";
    return false;
  }

  Translator t(out);
  Writer &W = t.W;
  W("#include <metal_stdlib>\nusing namespace metal;\n\n");

  // vertex inputs from dcl
  struct Input { unsigned reg; int slot; };
  std::vector<Input> inputs;
  t.IsPS = false;
  t.Ver = vs[0]&0xffff;
  t.Walk(vs,[&](unsigned op,const unsigned *p,int n,bool co)
  {
    if(op==OP_DCL && RegType(p[1])==REG_INPUT)
    {
      int slot;
      UsageName(p[0]&0x1f,(p[0]>>16)&0xf,slot);
      if(slot<0) t.Fail("dcl usage",p[0]&0x1f);
      Input in = { RegNum(p[1]), slot };
      inputs.push_back(in);
    }
  });

  W("struct VIn\n{\n");
  for(size_t i=0;i<inputs.size();i++)
    if(attribMask & (1u<<inputs[i].slot))
      W("  float4 a%d [[attribute(%d)]];\n",inputs[i].slot,inputs[i].slot);
  W("};\n\n");

  W("struct VOut\n{\n  float4 pos [[position,invariant]];   // multipass rendering uses zfunc equal\n  float4 d0;\n  float4 d1;\n");
  for(int i=0;i<4;i++) W("  float4 t%d;\n",i);
  W("};\n\n");

  // vertex function
  bool anyInput = false;
  for(size_t i=0;i<inputs.size();i++)
    if(attribMask & (1u<<inputs[i].slot)) anyInput = true;
  W("vertex VOut vsmain(%sconstant float4 *cb [[buffer(1)]])\n{\n",anyInput ? "VIn vin [[stage_in]]," : "");
  W("  float4 r0=0.0,r1=0.0,r2=0.0,r3=0.0,r4=0.0,r5=0.0,r6=0.0,r7=0.0,r8=0.0,r9=0.0,r10=0.0,r11=0.0;\n");
  W("  float4 oPos=float4(0.0,0.0,0.0,1.0),oD0=1.0,oD1=0.0,oFog=0.0,oPts=0.0;\n");
  W("  float4 oT0=0.0,oT1=0.0,oT2=0.0,oT3=0.0,oT4=0.0,oT5=0.0,oT6=0.0,oT7=0.0;\n");
  for(size_t i=0;i<inputs.size();i++)
  {
    if(attribMask & (1u<<inputs[i].slot))
      W("  float4 v%u = vin.a%d;\n",inputs[i].reg,inputs[i].slot);
    else
      W("  float4 v%u = float4(0.0,0.0,0.0,1.0);\n",inputs[i].reg);
  }
  t.CollectDefs(vs);
  t.Body(vs);
  W("  VOut o;\n  o.pos = oPos;\n  o.d0 = saturate(oD0);\n  o.d1 = saturate(oD1);\n");
  W("  o.t0 = oT0; o.t1 = oT1; o.t2 = oT2; o.t3 = oT3;\n  return o;\n}\n\n");

  // pixel function
  t.IsPS = true;
  t.Ver = ps[0]&0xffff;
  t.TexTypes = texTypes;
  if(t.Ver>=0x104) t.Fail("only ps 1.1-1.3 are supported",t.Ver);
  W("struct PSState\n{\n  int alphaFunc;\n  float alphaRef;\n};\n\n");
  W("fragment float4 psmain(VOut fin [[stage_in]],constant float4 *cb [[buffer(0)]],constant PSState &st [[buffer(1)]]");
  static const char *ttype[4] = { "texture2d","texturecube","texture3d","texture2d" };
  unsigned used = 0;
  t.Walk(ps,[&](unsigned op,const unsigned *p,int n,bool co)
  {
    if(op==OP_TEX && RegNum(p[0])<4) used |= 1u<<RegNum(p[0]);
  });
  for(int i=0;i<4;i++)
    if(used & (1u<<i))
      W(",\n  %s<float> tex%d [[texture(%d)]],sampler smp%d [[sampler(%d)]]",ttype[(texTypes>>(i*2))&3],i,i,i,i);
  W(")\n{\n");
  W("  float4 r0=0.0,r1=0.0,t0=0.0,t1=0.0,t2=0.0,t3=0.0;\n");
  W("  float4 v0 = saturate(fin.d0), v1 = saturate(fin.d1);\n");
  t.CollectDefs(ps);
  t.Body(ps);
  W("  float4 c = saturate(r0);\n");
  // alpha test, D3DCMPFUNC: 1 never .. 8 always
  W("  float a = round(c.a*255.0), ref = st.alphaRef;\n");
  W("  bool pass = st.alphaFunc==8 || (st.alphaFunc==2 && a<ref) || (st.alphaFunc==3 && a==ref) ||\n");
  W("    (st.alphaFunc==4 && a<=ref) || (st.alphaFunc==5 && a>ref) || (st.alphaFunc==6 && a!=ref) || (st.alphaFunc==7 && a>=ref);\n");
  W("  if(!pass) discard_fragment();\n");
  W("  return c;\n}\n");

  error = t.Err;
  return error.empty();
}
