#include "tasksys.h"
#include "itasksys.h"
#include <mutex>

IRunnable::~IRunnable() {}

ITaskSystem::ITaskSystem(int num_threads) {}
ITaskSystem::~ITaskSystem() {}

/*
 * ================================================================
 * Serial task system implementation
 * ================================================================
 */

const char *TaskSystemSerial::name() { return "Serial"; }

TaskSystemSerial::TaskSystemSerial(int num_threads)
    : ITaskSystem(num_threads) {}

TaskSystemSerial::~TaskSystemSerial() {}

void TaskSystemSerial::run(IRunnable *runnable, int num_total_tasks) {
  for (int i = 0; i < num_total_tasks; i++) {
    runnable->runTask(i, num_total_tasks);
  }
}

TaskID TaskSystemSerial::runAsyncWithDeps(IRunnable *runnable,
                                          int num_total_tasks,
                                          const std::vector<TaskID> &deps) {
  for (int i = 0; i < num_total_tasks; i++) {
    runnable->runTask(i, num_total_tasks);
  }

  return 0;
}

void TaskSystemSerial::sync() { return; }

/*
 * ================================================================
 * Parallel Task System Implementation
 * ================================================================
 */

const char *TaskSystemParallelSpawn::name() {
  return "Parallel + Always Spawn";
}

TaskSystemParallelSpawn::TaskSystemParallelSpawn(int num_threads)
    : ITaskSystem(num_threads) {
  // NOTE: CS149 students are not expected to implement TaskSystemParallelSpawn
  // in Part B.
}

TaskSystemParallelSpawn::~TaskSystemParallelSpawn() {}

void TaskSystemParallelSpawn::run(IRunnable *runnable, int num_total_tasks) {
  // NOTE: CS149 students are not expected to implement TaskSystemParallelSpawn
  // in Part B.
  for (int i = 0; i < num_total_tasks; i++) {
    runnable->runTask(i, num_total_tasks);
  }
}

TaskID TaskSystemParallelSpawn::runAsyncWithDeps(
    IRunnable *runnable, int num_total_tasks, const std::vector<TaskID> &deps) {
  // NOTE: CS149 students are not expected to implement TaskSystemParallelSpawn
  // in Part B.
  for (int i = 0; i < num_total_tasks; i++) {
    runnable->runTask(i, num_total_tasks);
  }

  return 0;
}

void TaskSystemParallelSpawn::sync() {
  // NOTE: CS149 students are not expected to implement TaskSystemParallelSpawn
  // in Part B.
  return;
}

/*
 * ================================================================
 * Parallel Thread Pool Spinning Task System Implementation
 * ================================================================
 */

const char *TaskSystemParallelThreadPoolSpinning::name() {
  return "Parallel + Thread Pool + Spin";
}

TaskSystemParallelThreadPoolSpinning::TaskSystemParallelThreadPoolSpinning(
    int num_threads)
    : ITaskSystem(num_threads) {
  // NOTE: CS149 students are not expected to implement
  // TaskSystemParallelThreadPoolSpinning in Part B.
}

TaskSystemParallelThreadPoolSpinning::~TaskSystemParallelThreadPoolSpinning() {}

void TaskSystemParallelThreadPoolSpinning::run(IRunnable *runnable,
                                               int num_total_tasks) {
  // NOTE: CS149 students are not expected to implement
  // TaskSystemParallelThreadPoolSpinning in Part B.
  for (int i = 0; i < num_total_tasks; i++) {
    runnable->runTask(i, num_total_tasks);
  }
}

TaskID TaskSystemParallelThreadPoolSpinning::runAsyncWithDeps(
    IRunnable *runnable, int num_total_tasks, const std::vector<TaskID> &deps) {
  // NOTE: CS149 students are not expected to implement
  // TaskSystemParallelThreadPoolSpinning in Part B.
  for (int i = 0; i < num_total_tasks; i++) {
    runnable->runTask(i, num_total_tasks);
  }

  return 0;
}

void TaskSystemParallelThreadPoolSpinning::sync() {
  // NOTE: CS149 students are not expected to implement
  // TaskSystemParallelThreadPoolSpinning in Part B.
  return;
}

/*
 * ================================================================
 * Parallel Thread Pool Sleeping Task System Implementation
 * ================================================================
 */

const char *TaskSystemParallelThreadPoolSleeping::name() {
  return "Parallel + Thread Pool + Sleep";
}

TaskSystemParallelThreadPoolSleeping::TaskSystemParallelThreadPoolSleeping(
    int num_threads)
    : ITaskSystem(num_threads) {
  //
  // TODO: CS149 student implementations may decide to perform setup
  // operations (such as thread pool construction) here.
  // Implementations are free to add new class member variables
  // (requiring changes to tasksys.h).
  //
  thread_pool.start(num_threads);
  task_id_counter.store(0);
}

TaskSystemParallelThreadPoolSleeping::~TaskSystemParallelThreadPoolSleeping() {
  //
  // TODO: CS149 student implementations may decide to perform cleanup
  // operations (such as thread pool shutdown construction) here.
  // Implementations are free to add new class member variables
  // (requiring changes to tasksys.h).
  //
}

void TaskSystemParallelThreadPoolSleeping::run(IRunnable *runnable,
                                               int num_total_tasks) {

  //
  // TODO: CS149 students will modify the implementation of this
  // method in Parts A and B.  The implementation provided below runs all
  // tasks sequentially on the calling thread.
  //

  for (int i = 0; i < num_total_tasks; i++) {
    runnable->runTask(i, num_total_tasks);
  }
}

TaskID TaskSystemParallelThreadPoolSleeping::runAsyncWithDeps(
    IRunnable *runnable, int num_total_tasks, const std::vector<TaskID> &deps) {
  TaskID task_id = task_id_counter.fetch_add(1);
  auto task_data = std::make_shared<TaskData>();
  task_data->runnable = runnable;
  task_data->num_total_tasks = num_total_tasks;
  task_data->task_id = task_id;
  task_data->remaining_tasks = num_total_tasks;
  task_data->dependencies_vec = deps;
  task_data->num_unfinished_deps = deps.size();
  task_data->ready = false;
  task_data->finished = false;

  {
    std::unique_lock<std::mutex> lock(launch_mutex);
    task_map[task_id] = task_data;
    // 反向记录依赖
    for (TaskID dep : deps) {
      auto it = task_map.find(dep);
      if (it != task_map.end()) {
        it->second->dependents.push_back(task_id);
      }
    }
    // 检查依赖是否都完成
    bool all_deps_done = true;
    for (TaskID dep : deps) {
      auto it = task_map.find(dep);
      if (it != task_map.end() && !it->second->finished) {
        all_deps_done = false;
        break;
      }
    }
    if (all_deps_done) {
      makeBatchReady(task_id);
    }
  }
  return task_id;
}

void TaskSystemParallelThreadPoolSleeping::sync() {
  std::unique_lock<std::mutex> lock(launch_mutex);
  launch_cv.wait(lock, [this]() {
    for (const auto &kv : task_map) {
      if (!kv.second->finished)
        return false;
    }
    return true;
  });
}
