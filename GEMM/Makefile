# CUDA编译器
NVCC = nvcc

# 编译标志
NVCCFLAGS = -O3 -arch=sm_75 -lineinfo
CXXFLAGS = -O3 -Wall -std=c++17

# 库文件
LIBS = -lcuda -lcudart -lcublas

# 目标文件
TARGET = gemm
SOURCES = gemm.cu

# 默认目标
all: $(TARGET)

# 编译规则
$(TARGET): $(SOURCES)
	$(NVCC) $(NVCCFLAGS) $(CXXFLAGS) -o $@ $< $(LIBS)

# 调试版本
debug: NVCCFLAGS += -g -G -DDEBUG
debug: CXXFLAGS += -g -DDEBUG
debug: $(TARGET)

# 清理
clean:
	rm -f $(TARGET)

# 运行
run: $(TARGET)
	./$(TARGET)

# 安装依赖检查
check:
	@echo "检查CUDA安装..."
	@nvcc --version || (echo "CUDA编译器未找到！请安装CUDA Toolkit"; exit 1)
	@echo "检查GPU..."
	@nvidia-smi || (echo "未检测到NVIDIA GPU或驱动未安装！"; exit 1)

.PHONY: all debug clean run check
