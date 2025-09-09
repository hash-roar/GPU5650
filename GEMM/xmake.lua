-- xmake.lua
set_project("cuda_example")
set_version("1.0.0")

-- 设置编译模式
add_rules("mode.debug", "mode.release")

target("cuda_app")
    set_kind("binary")
    
    -- 启用 CUDA 规则
    add_rules("cuda")
    
    -- 添加源文件
    add_files("gemm.cu")
    
    -- 设置 C++ 标准
    set_languages("c++17")
    
    -- CUDA 相关配置 - Try comprehensive architecture support
    add_cugencodes("native")
    
    -- 添加 CUDA 库
    add_links("cudart", "cublas", "curand")

    -- includes("./common.cuh")

    -- 编译选项
    add_cuflags("-O3")
    add_cxxflags("-O3")
    
    -- 链接目录（如果需要）
    if is_plat("linux") then
        add_linkdirs("/usr/local/cuda/lib64")
    elseif is_plat("windows") then
        add_linkdirs("$(env CUDA_PATH)/lib/x64")
    end

target("gemm")
    set_kind("binary")
    
    -- 启用 CUDA 规则
    add_rules("cuda")
    
    -- 添加源文件
    add_files("main.cu")
    
    -- 设置 C++ 标准
    set_languages("c++17")
    
    -- CUDA 相关配置 - Try comprehensive architecture support
    add_cugencodes("native")
    
    -- 添加 CUDA 库
    add_links("cudart", "cublas", "curand")

    -- includes("./common.cuh")

    -- 编译选项
    add_cuflags("-O3")
    add_cxxflags("-O3")
    
    -- 链接目录（如果需要）
    if is_plat("linux") then
        add_linkdirs("/usr/local/cuda/lib64")
    elseif is_plat("windows") then
        add_linkdirs("$(env CUDA_PATH)/lib/x64")
    end

target("cpu_gemm")
    set_kind("binary")
    

    -- 添加源文件
    add_files("cpu_gemm.cc")
    
    -- 设置 C++ 标准
    set_languages("c++17")
    -- add march("native")
    add_cxxflags("-march=native")
    -- add ffast-math
    add_cxxflags("-ffast-math")

    add_cxxflags("-O3")
    -- keep asmlevel output
    add_cxflags("-S", "-fverbose-asm")

    -- 链接目录（如果需要）
    if is_plat("linux") then
        add_linkdirs("/usr/local/cuda/lib64")
    elseif is_plat("windows") then
        add_linkdirs("$(env CUDA_PATH)/lib/x64")
    end
