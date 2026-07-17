CXX ?= g++
CXXFLAGS ?= -O2
CXXFLAGS += -shared -fPIC -std=c++2b -Wno-c++11-narrowing --no-gnu-unique
INCLUDES := $(shell pkg-config --cflags pixman-1 libdrm hyprland libinput libudev wayland-server xkbcommon)
SOURCES := src/main.cpp src/barDeco.cpp src/BarPassElement.cpp
TARGET := enoshima-decoration.so

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SOURCES)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) $(INCLUDES) $(SOURCES) -o $@

clean:
	$(RM) $(TARGET)
