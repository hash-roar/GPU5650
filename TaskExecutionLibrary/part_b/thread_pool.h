#include <vector>
#include <queue>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <functional>
#include <future>
#include <atomic>
#include <memory>
#include <stdexcept>
#include <iostream>
#include <type_traits>

class ThreadPool {
public:
    enum class Priority {
        LOW = 0,
        NORMAL = 1,
        HIGH = 2
    };

    struct PoolStatus {
        size_t num_threads;
        size_t active_threads;
        size_t queued_tasks;
        size_t completed_tasks;
        bool is_running;
    };

private:
    // 任务包装器
    struct Task {
        std::function<void()> func;
        Priority priority;
        
        Task(std::function<void()> f, Priority p) 
            : func(std::move(f)), priority(p) {}
        
        // 优先级比较，用于优先队列
        bool operator<(const Task& other) const {
            return priority < other.priority;
        }
    };

public:
    explicit ThreadPool(size_t max_queue_size = 0) 
        : max_queue_size_(max_queue_size), 
          stop_(false),
          active_threads_(0),
          completed_tasks_(0) {
    }

    ~ThreadPool() {
        shutdown();
    }

    // 禁用拷贝和移动
    ThreadPool(const ThreadPool&) = delete;
    ThreadPool& operator=(const ThreadPool&) = delete;
    ThreadPool(ThreadPool&&) = delete;
    ThreadPool& operator=(ThreadPool&&) = delete;

    // 启动线程池
    void start(size_t num_threads) {
        std::unique_lock<std::mutex> lock(queue_mutex_);
        if (!threads_.empty()) {
            throw std::runtime_error("ThreadPool already started");
        }
        
        for (size_t i = 0; i < num_threads; ++i) {
            threads_.emplace_back(&ThreadPool::worker, this);
        }
    }

    // 提交任务（无返回值）
    void enqueue(std::function<void()> task, Priority priority = Priority::NORMAL) {
        {
            std::unique_lock<std::mutex> lock(queue_mutex_);
            
            if (stop_) {
                throw std::runtime_error("enqueue on stopped ThreadPool");
            }
            
            // 检查队列大小限制
            if (max_queue_size_ > 0 && tasks_.size() >= max_queue_size_) {
                // 等待队列有空间
                queue_not_full_.wait(lock, [this] { 
                    return stop_ || tasks_.size() < max_queue_size_; 
                });
                
                if (stop_) {
                    throw std::runtime_error("ThreadPool is stopping");
                }
            }
            
            tasks_.emplace(std::move(task), priority);
        }
        condition_.notify_one();
    }

    // // 提交任务（有返回值）
    // template<typename F, typename... Args>
    // auto submit(F&& f, Args&&... args, Priority priority = Priority::NORMAL) 
    //     -> std::future<typename std::invoke_result<F, Args...>::type> {
        
    //     using return_type = typename std::invoke_result<F, Args...>::type;
        
    //     auto task = std::make_shared<std::packaged_task<return_type()>>(
    //         std::bind(std::forward<F>(f), std::forward<Args>(args)...)
    //     );
        
    //     std::future<return_type> res = task->get_future();
        
    //     {
    //         std::unique_lock<std::mutex> lock(queue_mutex_);
            
    //         if (stop_) {
    //             throw std::runtime_error("submit on stopped ThreadPool");
    //         }
            
    //         // 检查队列大小限制
    //         if (max_queue_size_ > 0 && tasks_.size() >= max_queue_size_) {
    //             queue_not_full_.wait(lock, [this] { 
    //                 return stop_ || tasks_.size() < max_queue_size_; 
    //             });
                
    //             if (stop_) {
    //                 throw std::runtime_error("ThreadPool is stopping");
    //             }
    //         }
            
    //         tasks_.emplace([task]() { (*task)(); }, priority);
    //     }
        
    //     condition_.notify_one();
    //     return res;
    // }

    // 等待所有任务完成
    void wait() {
        std::unique_lock<std::mutex> lock(queue_mutex_);
        wait_condition_.wait(lock, [this] { 
            return tasks_.empty() && active_threads_ == 0; 
        });
    }

    // 获取线程池状态
    PoolStatus getStatus() const {
        std::unique_lock<std::mutex> lock(queue_mutex_);
        return {
            threads_.size(),
            active_threads_,
            tasks_.size(),
            completed_tasks_,
            !stop_
        };
    }

    // 优雅关闭（等待所有任务完成）
    void shutdown() {
        {
            std::unique_lock<std::mutex> lock(queue_mutex_);
            stop_ = true;
        }
        condition_.notify_all();
        queue_not_full_.notify_all();
        
        for (std::thread& thread : threads_) {
            if (thread.joinable()) {
                thread.join();
            }
        }
        threads_.clear();
    }

    // 立即关闭（丢弃未执行的任务）
    void shutdownNow() {
        {
            std::unique_lock<std::mutex> lock(queue_mutex_);
            stop_ = true;
            // 清空任务队列
            while (!tasks_.empty()) {
                tasks_.pop();
            }
        }
        condition_.notify_all();
        queue_not_full_.notify_all();
        
        for (std::thread& thread : threads_) {
            if (thread.joinable()) {
                thread.join();
            }
        }
        threads_.clear();
    }

    // 获取队列大小
    size_t getQueueSize() const {
        std::unique_lock<std::mutex> lock(queue_mutex_);
        return tasks_.size();
    }

    // 设置最大队列大小（0表示无限制）
    void setMaxQueueSize(size_t size) {
        std::unique_lock<std::mutex> lock(queue_mutex_);
        max_queue_size_ = size;
        queue_not_full_.notify_all();
    }

private:
    void worker() {
        while (true) {
            Task task(nullptr, Priority::NORMAL);
            
            {
                std::unique_lock<std::mutex> lock(queue_mutex_);
                
                condition_.wait(lock, [this] { 
                    return stop_ || !tasks_.empty(); 
                });
                
                if (stop_ && tasks_.empty()) {
                    return;
                }
                
                task = std::move(const_cast<Task&>(tasks_.top()));
                tasks_.pop();
                ++active_threads_;
                
                // 通知可能在等待队列空间的线程
                if (max_queue_size_ > 0) {
                    queue_not_full_.notify_one();
                }
            }
            
            // 执行任务
            try {
                if (task.func) {
                    task.func();
                }
            } catch (const std::exception& e) {
                // 处理任务执行中的异常
                std::cerr << "Task execution error: " << e.what() << std::endl;
            } catch (...) {
                // 捕获其他未知异常
                std::cerr << "Unknown task execution error." << std::endl;
                
            }
            
            // 更新状态
            {
                std::unique_lock<std::mutex> lock(queue_mutex_);
                --active_threads_;
                ++completed_tasks_;
                
                // 如果没有活动线程且队列为空，通知wait()
                if (active_threads_ == 0 && tasks_.empty()) {
                    wait_condition_.notify_all();
                }
            }
        }
    }

private:
    std::vector<std::thread> threads_;
    std::priority_queue<Task> tasks_;
    
    mutable std::mutex queue_mutex_;
    std::condition_variable condition_;
    std::condition_variable queue_not_full_;
    std::condition_variable wait_condition_;
    
    std::atomic<bool> stop_;
    size_t max_queue_size_;
    size_t active_threads_;
    size_t completed_tasks_;
};