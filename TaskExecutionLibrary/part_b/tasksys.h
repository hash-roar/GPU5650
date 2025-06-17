#ifndef _TASKSYS_H
#define _TASKSYS_H

#include "itasksys.h"
#include "thread_pool.h"
#include <atomic>
#include <condition_variable>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <vector>

/*
 * TaskSystemSerial: This class is the student's implementation of a
 * serial task execution engine.  See definition of ITaskSystem in
 * itasksys.h for documentation of the ITaskSystem interface.
 */
class TaskSystemSerial : public ITaskSystem {
public:
  TaskSystemSerial(int num_threads);
  ~TaskSystemSerial();
  const char *name();
  void run(IRunnable *runnable, int num_total_tasks);
  TaskID runAsyncWithDeps(IRunnable *runnable, int num_total_tasks,
                          const std::vector<TaskID> &deps);
  void sync();
};

/*
 * TaskSystemParallelSpawn: This class is the student's implementation of a
 * parallel task execution engine that spawns threads in every run()
 * call.  See definition of ITaskSystem in itasksys.h for documentation
 * of the ITaskSystem interface.
 */
class TaskSystemParallelSpawn : public ITaskSystem {
public:
  TaskSystemParallelSpawn(int num_threads);
  ~TaskSystemParallelSpawn();
  const char *name();
  void run(IRunnable *runnable, int num_total_tasks);
  TaskID runAsyncWithDeps(IRunnable *runnable, int num_total_tasks,
                          const std::vector<TaskID> &deps);
  void sync();
};

/*
 * TaskSystemParallelThreadPoolSpinning: This class is the student's
 * implementation of a parallel task execution engine that uses a
 * thread pool. See definition of ITaskSystem in itasksys.h for
 * documentation of the ITaskSystem interface.
 */
class TaskSystemParallelThreadPoolSpinning : public ITaskSystem {
public:
  TaskSystemParallelThreadPoolSpinning(int num_threads);
  ~TaskSystemParallelThreadPoolSpinning();
  const char *name();
  void run(IRunnable *runnable, int num_total_tasks);
  TaskID runAsyncWithDeps(IRunnable *runnable, int num_total_tasks,
                          const std::vector<TaskID> &deps);
  void sync();
};

/*
 * TaskSystemParallelThreadPoolSleeping: This class is the student's
 * optimized implementation of a parallel task execution engine that uses
 * a thread pool. See definition of ITaskSystem in
 * itasksys.h for documentation of the ITaskSystem interface.
 */
class TaskSystemParallelThreadPoolSleeping : public ITaskSystem {
public:
  struct TaskData {
    IRunnable *runnable;
    int num_total_tasks;
    TaskID task_id;
    std::atomic<int> remaining_tasks;
    std::vector<TaskID> dependencies_vec;
    std::vector<TaskID> dependents;
    std::atomic<int> num_unfinished_deps;
    std::atomic<bool> ready;
    std::atomic<bool> finished;
    TaskData()
        : runnable(nullptr), num_total_tasks(0), task_id(0), remaining_tasks(0),
          num_unfinished_deps(0), ready(false), finished(false) {}
  };

public:
  TaskSystemParallelThreadPoolSleeping(int num_threads);
  ~TaskSystemParallelThreadPoolSleeping();
  const char *name();
  void run(IRunnable *runnable, int num_total_tasks);
  TaskID runAsyncWithDeps(IRunnable *runnable, int num_total_tasks,
                          const std::vector<TaskID> &deps);
  void sync();

private:
  void makeBatchReady(TaskID task_id) {
    auto task_data = task_map[task_id];
    task_data->ready = true;
    for (int i = 0; i < task_data->num_total_tasks; ++i) {
      // 捕获shared_ptr防止悬挂
      thread_pool.enqueue([this, task_data, i]() {
        task_data->runnable->runTask(i, task_data->num_total_tasks);
        bool batch_finished = false;
        {
          std::unique_lock<std::mutex> lock(launch_mutex);
          int left = --task_data->remaining_tasks;
          if (left == 0) {
            task_data->finished = true;
            batch_finished = true;
            // 通知所有依赖它的批次
            for (TaskID dep : task_data->dependents) {
              auto &dep_task = task_map[dep];
              int left_deps = --dep_task->num_unfinished_deps;
              if (left_deps == 0 && !dep_task->ready) {
                makeBatchReady(dep);
              }
            }
            launch_cv.notify_all();
          }
        }
      });
    }
  }

  std::condition_variable launch_cv;
  std::mutex launch_mutex;
  std::atomic_int task_id_counter;
  // 用shared_ptr避免悬挂
  std::unordered_map<TaskID, std::shared_ptr<TaskData>> task_map;
  ThreadPool thread_pool;
};

#endif
