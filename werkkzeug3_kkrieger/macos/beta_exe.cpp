// Reads the game data out of pno0001.exe, the .kkrieger beta release (2004).
//
// The release terms allow passing the archive around only unmodified, so the
// data is not part of this repository: the player unpacks it from the user's
// copy of the executable at start.
//
// The executable is packed with an early kkrunchy: a range coder with eight
// adaptive frequency models and LZ matches. This is a C translation of its
// depacker stub (VA 0x7d7a0c). The data block is at VA 0x82168c in the
// unpacked image.

#include "_types.hpp"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

namespace {

const uint32_t BASE = 0x7c0000;       // image base, file offset 0
const uint32_t IMAGESIZE = 0x1000+0xd85257+0x10000;
const uint32_t DATAVA = 0x82168c;
const uint32_t SRCVA = 0x7c00d4;      // packed stream
const uint32_t DSTVA = 0x7e3da9;      // unpacked image starts here
const uint32_t TABVA = 0x7d7b8f;      // model table of the stub
const long EXESIZE = 97280;

struct Unpacker
{
  uint8_t *Img;
  uint32_t Src,Low,Range,R0;
  uint32_t Mem[8192];
  uint32_t *Model[8];
  bool Bad;

  uint8_t *P(uint32_t va)
  {
    if(va-BASE>=IMAGESIZE-4) { Bad = true; return Img; }
    return Img+(va-BASE);
  }

  int Decode(uint32_t *m)             // returns symbol (0-based)
  {
    Range /= m[0];
    uint32_t v; memcpy(&v,P(Src),4);
    uint32_t count = (__builtin_bswap32(v)-Low)/Range;
    int32_t e = (int32_t)count;
    uint32_t sym = 0;
    do { sym++; e -= (int32_t)m[sym]; } while(e>=0 && m[sym+1]);
    uint32_t freq = m[sym];
    m[sym] += 2;
    uint32_t a = (uint32_t)(e+(int32_t)freq);          // count - cumhigh + freq
    a = (uint32_t)(-(int32_t)a)+count;                 // cumlow
    a = a*Range+Low;
    uint32_t d = freq*Range;
    for(;;)
    {
      uint32_t s = (a+d)^a;
      if(s>=0x1000000u)
      {
        if(d>=0x10000u) break;
        d = (uint32_t)(uint16_t)(-(uint16_t)a);
      }
      Src++; a <<= 8; d <<= 8;
    }
    Low = a; Range = d;
    uint32_t t = m[0]+2;
    if(t>=m[-1])
      for(int i=1;m[i];i++) { uint32_t c = m[i]>>1; m[i] -= c; t -= c; }
    m[0] = t;
    return (int)sym-1;
  }

  uint32_t Gamma(uint32_t *m)
  {
    uint32_t c = 1;
    int s;
    do { s = Decode(m); c = c*2+(s&1); } while((s>>1)==1 && !Bad);
    return c;
  }

  bool Run()
  {
    const uint8_t *tab = P(TABVA);
    uint32_t *w = Mem;
    for(int k=7;k>=0;k--)
    {
      *w++ = 0; *w++ = (uint32_t)tab[0]*8; Model[k] = w;
      uint32_t cnt = (uint32_t)tab[1]+1; tab += 2;
      *w++ = cnt;
      for(uint32_t i=0;i<cnt;i++) *w++ = 1;
    }
    *w++ = 0;
    Src = SRCVA; Low = 0; Range = 0xffffffffu; R0 = 0;

    uint32_t dst = DSTVA;
    bool afterLiteral = true;
    *P(dst++) = (uint8_t)Decode(Model[0]);
    while(!Bad)
    {
      if(Decode(afterLiteral ? Model[3] : Model[4])==0)
      {
        *P(dst++) = (uint8_t)Decode(Model[0]);
        afterLiteral = true;
        continue;
      }
      uint32_t len,offs;
      if(afterLiteral && Decode(Model[7])!=0)
      {
        len = Gamma(Model[2]);
        offs = R0;
      }
      else
      {
        int32_t c = (int32_t)Gamma(Model[1])-2;
        if(c<0) break;                // end of stream
        c <<= 4;
        offs = (uint32_t)Decode(c ? Model[6] : Model[5])+c+1;
        len = Gamma(Model[2]);
        if(offs>=0x800) len++;
        if(offs>=0x60) len++;
      }
      R0 = offs;
      for(uint32_t i=0;i<len && !Bad;i++,dst++)
        *P(dst) = *P(dst-offs);
      afterLiteral = false;
    }
    return !Bad;
  }
};

}

// returns the data block, or 0 if the file is not the beta executable
sU8 *LoadBetaExe(const sChar *name,sInt &size)
{
  FILE *f = fopen(name,"rb");
  if(!f) return 0;
  fseek(f,0,SEEK_END);
  long n = ftell(f);
  fseek(f,0,SEEK_SET);
  if(n!=EXESIZE) { fclose(f); return 0; }

  Unpacker *u = new Unpacker;
  memset(u,0,sizeof(*u));
  u->Img = (uint8_t *)calloc(IMAGESIZE,1);
  bool ok = fread(u->Img,1,n,f)==(size_t)n;
  fclose(f);

  sU8 *result = 0;
  if(ok && u->Run())
  {
    const uint8_t *d = u->Img+(DATAVA-BASE);
    uint32_t songsize;
    memcpy(&songsize,d,4);
    if(songsize==27031)               // the beta's song
    {
      size = 0x40000;                 // the data block is about 120 KB
      result = new sU8[size];
      memcpy(result,d,size);
    }
  }
  free(u->Img);
  delete u;
  return result;
}
