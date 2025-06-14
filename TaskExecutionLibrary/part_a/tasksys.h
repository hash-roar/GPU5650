#ifndef _TASKSYS_H
#define _TASKSYS_H

#include "itasksys.h"
#include <condition_variable>
#include <cstdio>
#include <functional>
#include <mutex>
#include <queue>
#include <thread>
#include <vector>

/*
 * TaskSystemSerial: This class is the student's implementation of a
 * serial task execution engine.  See definition of ITaskSystem in
 * itasksys.h for documentation of the ITaskSystem interface.
 */
class TaskSystemSerial: public ITaskSystem {
    public:
        TaskSystemSerial(int num_threads);
        ~TaskSystemSerial();
        const char* name();
        void run(IRunnable* runnable, int num_total_tasks);
        TaskID runAsyncWithDeps(IRunnable* runnable, int num_total_tasks,
                                const std::vector<TaskID>& deps);
        void sync();
};

/*
 * TaskSystemParallelSpawn: This class is the student's implementation of a
 * parallel task execution engine that spawns threads in every run()
 * call.  See definition of ITaskSystem in itasksys.h for documentation
 * of the ITaskSystem interface.
 */
class TaskSystemParallelSpawn: public ITaskSystem {
    public:
        TaskSystemParallelSpawn(int num_threads);
        ~TaskSystemParallelSpawn();
        const char* name();
        void run(IRunnable* runnable, int num_total_tasks);
        TaskID runAsyncWithDeps(IRunnable* runnable, int num_total_tasks,
                                const std::vector<TaskID>& deps);
        void sync();
};

/*
 * TaskSystemParallelThreadPoolSpinning: This class is the student's
 * implementation of a parallel task execution engine that uses a
 * thread pool. See definition of ITaskSystem in itasksys.h for
 * documentation of the ITaskSystem interface.
 */
class TaskSystemParallelThreadPoolSpinning: public ITaskSystem {
    public:
        TaskSystemParallelThreadPoolSpinning(int num_threads);
        ~TaskSystemParallelThreadPoolSpinning();
        const char* name();
        void run(IRunnable* runnable, int num_total_tasks);
        TaskID runAsyncWithDeps(IRunnable* runnable, int num_total_tasks,
                                const std::vector<TaskID>& deps);
        void sync();
    public:
        class  ThreadPool {
        public:
             ThreadPool ()=default;
            ~ ThreadPool () {
                stopAll();
            }
            ThreadPool(const ThreadPool&) = delete;
            ThreadPool& operator=(const ThreadPool&) = delete;
            ThreadPool(ThreadPool&&) = delete;
            ThreadPool& operator=(ThreadPool&&) = delete;

            void enqueue(std::function<void()> task){
                std::unique_lock<std::mutex> lock(queue_mutex);
                tasks.push(std::move(task));
                condition.notify_one();
            }
            bool isEmpty() {
                std::unique_lock<std::mutex> lock(queue_mutex);
                return tasks.empty();
            }
            void waitForTasks() {
                std::unique_lock<std::mutex> lock(queue_mutex);
                stop = true;
                condition.notify_all();
                condition.wait(lock, [this] { return tasks.empty(); });
            }
            void start(int num_threads) {
                stop = false;
                for (int i = 0; i < num_threads; ++i) {
                    threads.emplace_back(&ThreadPool::worker, this);
                }
            }
            void stopAll() {
                {
                    std::unique_lock<std::mutex> lock(queue_mutex);
                    stop = true;
                }
                condition.notify_all();
                for (std::thread &thread : threads) {
                    if (thread.joinable()) {
                        thread.join();
                    }
                }
            }
            void clear() {
                std::unique_lock<std::mutex> lock(queue_mutex);
                while (!tasks.empty()) {
                    tasks.pop();
                }
            }
        private:
            std::vector<std::thread> threads;
            std::queue<std::function<void()>> tasks;
            std::mutex queue_mutex;
            std::condition_variable condition;
            bool stop{false};
            void worker(){
                while (true) {
                    std::function<void()> task;
                    {
                        std::unique_lock<std::mutex> lock(queue_mutex);
                        condition.wait(lock, [this] { return stop || !tasks.empty(); });
                        if (stop && tasks.empty()) {
                            // printf("Thread exiting\n");
                            condition.notify_one();
                            return;
                        }
                        // printf("Thread executing task\n");
                        task = std::move(tasks.front());
                        tasks.pop();
                    }
                    task();
                }
            }
        };
        private:
            ThreadPool thread_pool{};
};

/*
 * TaskSystemParallelThreadPoolSleeping: This class is the student's
 * optimized implementation of a parallel task execution engine that uses
 * a thread pool. See definition of ITaskSystem in
 * itasksys.h for documentation of the ITaskSystem interface.
 */
class TaskSystemParallelThreadPoolSleeping: public ITaskSystem {
    public:
        TaskSystemParallelThreadPoolSleeping(int num_threads);
        ~TaskSystemParallelThreadPoolSleeping();
        const char* name();
        void run(IRunnable* runnable, int num_total_tasks);
        TaskID runAsyncWithDeps(IRunnable* runnable, int num_total_tasks,
                                const std::vector<TaskID>& deps);
        void sync();
};

#endif
