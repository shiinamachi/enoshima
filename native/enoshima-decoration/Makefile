CXX ?= g++
CXXFLAGS ?= -O2
CXXFLAGS += -shared -fPIC -std=c++2b -Wall -Wextra -Wformat=2 -Werror --no-gnu-unique
PKG_INCLUDES := $(shell pkg-config --cflags pixman-1 libdrm hyprland libinput libudev wayland-server xkbcommon)
INCLUDES := $(patsubst -I%,-isystem %,$(PKG_INCLUDES))
SOURCES := src/main.cpp src/barDeco.cpp src/BarPassElement.cpp
TARGET := enoshima-decoration.so

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SOURCES)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) $(INCLUDES) $(SOURCES) -o $@

clean:
	$(RM) $(TARGET)
