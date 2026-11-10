# Build hook.dylib for iOS arm64. Requires macOS + Xcode command line tools.
SDK      := $(shell xcrun --sdk iphoneos --show-sdk-path)
CXX      := xcrun --sdk iphoneos clang++
CXXFLAGS := -arch arm64 -isysroot $(SDK) -miphoneos-version-min=13.0 -std=c++17 -O2 -fobjc-arc
LDFLAGS  := -dynamiclib -framework Foundation -framework UIKit \
            -install_name @executable_path/Frameworks/hook.dylib

build/hook.dylib: src/hook.mm
	@mkdir -p build
	$(CXX) $(CXXFLAGS) $(LDFLAGS) $< -o $@
	@echo "built $@"

clean:
	rm -rf build
