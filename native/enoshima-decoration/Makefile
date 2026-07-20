CXX ?= g++
CXXFLAGS ?= -O2
CXXFLAGS += -shared -fPIC -std=c++2b -Wall -Wextra -Wformat=2 -Werror --no-gnu-unique
PKG_MODULES := pixman-1 libdrm hyprland libinput libudev wayland-server xkbcommon librsvg-2.0
PKG_INCLUDES := $(shell pkg-config --cflags $(PKG_MODULES))
PKG_LIBS := $(shell pkg-config --libs librsvg-2.0)
INCLUDES := $(patsubst -I%,-isystem %,$(PKG_INCLUDES))
SOURCES := src/main.cpp src/barDeco.cpp src/BarPassElement.cpp
TARGET := enoshima-decoration.so

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SOURCES)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) $(INCLUDES) $(SOURCES) $(PKG_LIBS) -o $@

clean:
	$(RM) $(TARGET)
