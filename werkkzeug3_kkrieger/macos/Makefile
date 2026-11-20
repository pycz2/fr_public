# Native macOS build of the .kkrieger player.
#
#   make            build build/kkrieger
#   make clean
#
# Needs only Xcode (clang) and the system frameworks.

ROOT     := ..
V2       := $(ROOT)/../v2
BUILD    := build

CXX      := clang++
OPT      ?= -Os
# -fno-delete-null-pointer-checks: the code tests "this" against 0 (KOp::CalcUsed,
# KOp::CheckOutput), which old MSVC allowed and clang would otherwise remove
# -ffp-contract=off: no fused multiply-add. x87 had none, and mixing fused and
# unfused versions of the same expression breaks the geometry code (collision)
COMMON   := -std=c++17 -fms-extensions -fno-exceptions -fno-rtti -fno-delete-null-pointer-checks \
            -ffp-contract=off $(OPT) -g \
            -Wno-everything -I$(ROOT) -I$(ROOT)/materials -I$(BUILD)
PLAYERFLAGS := $(COMMON) -include $(ROOT)/player_kkrieger/kkrieger_config.hpp -DKKRIEGER
V2FLAGS  := -std=c++17 -fms-extensions -fno-exceptions -fno-rtti $(OPT) -g -Wno-everything -I$(V2)

# --- shader assembler (tool, runs at build time) --------------------------

SCFLAGS  := $(COMMON) -include tool_config.hpp -I$(ROOT)/base_console
SC_OBJ   := $(BUILD)/sc/console_mac.o $(BUILD)/sc/scmain.o $(BUILD)/sc/shadercompile.o $(BUILD)/sc/_types.o
SC       := $(BUILD)/shadercompile

$(BUILD)/sc/console_mac.o: console_mac.cpp | $(BUILD)/sc
	$(CXX) $(SCFLAGS) -c $< -o $@
$(BUILD)/sc/scmain.o: $(ROOT)/shadercompile/main.cpp | $(BUILD)/sc
	$(CXX) $(SCFLAGS) -c $< -o $@
$(BUILD)/sc/%.o: $(ROOT)/%.cpp | $(BUILD)/sc
	$(CXX) $(SCFLAGS) -c $< -o $@

$(SC): $(SC_OBJ)
	$(CXX) -o $@ $^

# generated shader headers
GEN      := $(BUILD)/effect_jpegps.hpp $(BUILD)/effect_jpegvs.hpp

$(BUILD)/effect_jpegps.hpp: $(ROOT)/werkkzeug3/effect_jpeg.psh $(SC)
	cd $(dir $<) && $(CURDIR)/$(SC) --out-header $(CURDIR)/$@ $(notdir $<)
$(BUILD)/effect_jpegvs.hpp: $(ROOT)/werkkzeug3/effect_jpeg.vsh $(SC)
	cd $(dir $<) && $(CURDIR)/$(SC) --out-header $(CURDIR)/$@ $(notdir $<)

# --- player -----------------------------------------------------------------

PLAYER_SRC := materials/material11.cpp materials/rtmanager.cpp shadercodegen.cpp \
              _viruz2.cpp _types.cpp genbitmap.cpp genblobspline.cpp geneffect.cpp \
              genmaterial.cpp genmesh.cpp genoverlay.cpp genscene.cpp engine.cpp \
              kdoc.cpp player_kkrieger/kkrieger_oplist.cpp kkriegergame.cpp mainplayer.cpp
PLAYER_OBJ := $(patsubst %.cpp,$(BUILD)/obj/%.o,$(notdir $(PLAYER_SRC)))
MAC_OBJ    := $(BUILD)/obj/_start_mac.o $(BUILD)/obj/sound_mac.o $(BUILD)/obj/v2bridge.o
V2_SRC     := synth_core.cpp ronan.cpp v2mplayer.cpp v2mconv.cpp
V2_OBJ     := $(patsubst %.cpp,$(BUILD)/v2/%.o,$(V2_SRC))
FRAMEWORKS := -framework AppKit -framework Metal -framework QuartzCore -framework AudioToolbox -framework GameController

vpath %.cpp $(ROOT) $(ROOT)/materials $(ROOT)/player_kkrieger

$(BUILD)/obj/%.o: %.cpp $(GEN) | $(BUILD)/obj
	$(CXX) $(PLAYERFLAGS) -c $< -o $@
$(BUILD)/obj/%.o: %.mm | $(BUILD)/obj
	$(CXX) $(PLAYERFLAGS) -fobjc-arc -c $< -o $@
$(BUILD)/obj/v2bridge.o: v2bridge.cpp | $(BUILD)/obj
	$(CXX) $(V2FLAGS) -c $< -o $@
$(BUILD)/v2/%.o: $(V2)/%.cpp | $(BUILD)/v2
	$(CXX) $(V2FLAGS) -include $(V2)/types.h -c $< -o $@

$(BUILD)/kkrieger: $(PLAYER_OBJ) $(MAC_OBJ) $(V2_OBJ)
	$(CXX) -o $@ $^ $(FRAMEWORKS) -Wl,-dead_strip

all: $(BUILD)/kkrieger
.DEFAULT_GOAL := all

$(BUILD) $(BUILD)/sc $(BUILD)/obj $(BUILD)/v2:
	mkdir -p $@

clean:
	rm -rf $(BUILD)

.PHONY: clean all
