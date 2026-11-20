// This file is distributed under a BSD license. See LICENSE.txt for details.

// macOS version of base_console/_startconsole.cpp (used by shadercompile)

#include "_types.hpp"
#include "base_console/_startconsole.hpp"
#include "macos/fileio_mac.hpp"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

sSystem_ *sSystem;
class sBroker_ *sBroker;
sInt sFatality = 0;

int main(int argc,char **argv)
{
  sInt ret;

  sBroker = new sBroker_;
  sSystem = new sSystem_;
  ret = sAppMain(argc,argv);
  delete sSystem;
  delete sBroker;

  return ret;
}

void sSystem_::Log(sChar *s)
{
  fputs(s,stderr);
}

sNORETURN void sSystem_::Abort(sChar *msg)
{
  if(msg)
    fprintf(stderr,"fatal error: %s\n",msg);
  exit(1);
}

void sSystem_::Tag()
{
}

void sSystem_::PrintF(const sChar *format,...)
{
  sChar buffer[2048];
  sFORMAT_CALL(sFormatString(buffer,2048,format,FA),format);
  fputs(buffer,stdout);
}

sU8 *sSystem_::LoadFile(const sChar *name,sInt &size)
{
  return sMacLoadFile(name,size);
}

sU8 *sSystem_::LoadFile(const sChar *name)
{
  sInt dummy;
  return sMacLoadFile(name,dummy);
}

sChar *sSystem_::LoadText(const sChar *name)
{
  sInt dummy;
  return (sChar *) sMacLoadFile(name,dummy,1);
}

sBool sSystem_::SaveFile(const sChar *name,const sU8 *data,sInt size)
{
  return sMacSaveFile(name,data,size);
}

sInt sSystem_::GetTime()
{
  return (sInt)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1000000);
}
