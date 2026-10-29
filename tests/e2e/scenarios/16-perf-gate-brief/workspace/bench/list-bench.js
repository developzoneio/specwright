// Measures TodoService.listTodos latency with 3000 todos in the store, in milliseconds.
// Three runs of 40 timed calls after 5 warm-up calls; prints one JSON object on one line.
import { performance } from 'node:perf_hooks';
import { TodoService } from '../src/application/todo-service.js';
import { InMemoryStore } from '../src/infrastructure/store.js';

const TODOS = 3000;
const RUNS = 3;
const WARMUP_CALLS = 5;
const TIMED_CALLS = 40;

function percentile(sorted, p) {
  return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)];
}

function round(value) {
  return Math.round(value * 1000) / 1000;
}

function summarize(samples) {
  const sorted = [...samples].sort((a, b) => a - b);
  return { p50: round(percentile(sorted, 50)), p95: round(percentile(sorted, 95)), p99: round(percentile(sorted, 99)) };
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

const service = new TodoService(new InMemoryStore());
for (let i = 0; i < TODOS; i++) {
  service.addTodo(`todo ${i}`);
}

const runs = [];
for (let r = 0; r < RUNS; r++) {
  for (let i = 0; i < WARMUP_CALLS; i++) {
    service.listTodos();
  }
  const samples = [];
  for (let i = 0; i < TIMED_CALLS; i++) {
    const start = performance.now();
    service.listTodos();
    samples.push(performance.now() - start);
  }
  runs.push(summarize(samples));
}

const result = {
  metric: 'listTodos latency',
  unit: 'ms',
  todos: TODOS,
  runs,
  median: {
    p50: median(runs.map((x) => x.p50)),
    p95: median(runs.map((x) => x.p95)),
    p99: median(runs.map((x) => x.p99))
  }
};
console.log(JSON.stringify(result));
