// This file is distributed under a BSD license. See LICENSE.txt for details.

// whole-file load/save with stdio, shared by the console tools and the player

#ifndef __FILEIO_MAC_HPP__
#define __FILEIO_MAC_HPP__

#include "_types.hpp"
#include <stdio.h>

// returns new[]'d buffer with 'extra' zero bytes appended, or 0
static sU8 *sMacLoadFile(const sChar *name,sInt &size,sInt extra=0)
{
  FILE *f = fopen(name,"rb");
  if(!f)
    return 0;
  fseek(f,0,SEEK_END);
  long len = ftell(f);
  fseek(f,0,SEEK_SET);
  sU8 *mem = 0;
  if(len>=0)
  {
    mem = new sU8[len+extra];
    if(fread(mem,1,len,f)!=(size_t)len)
    {
      delete[] mem;
      mem = 0;
    }
    else
    {
      sSetMem(mem+len,0,extra);
      size = (sInt)len;
    }
  }
  fclose(f);
  return mem;
}

static sBool sMacSaveFile(const sChar *name,const sU8 *data,sInt size)
{
  FILE *f = fopen(name,"wb");
  if(!f)
    return sFALSE;
  sBool ok = fwrite(data,1,size,f)==(size_t)size;
  return fclose(f)==0 && ok;
}

#endif
