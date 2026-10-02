import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TodoService, TodoNotFoundError } from '../src/application/todo-service.js';
import { InMemoryStore } from '../src/infrastructure/store.js';
import { InvalidPriorityError } from '../src/domain/todo.js';

function makeService() {
  return new TodoService(new InMemoryStore());
}

test('addTodo stores and returns a new todo', () => {
  const service = makeService();
  const todo = service.addTodo('Buy milk');
  assert.equal(todo.title, 'Buy milk');
  assert.equal(todo.done, false);
  assert.equal(service.listTodos().length, 1);
});

test('completeTodo marks an existing todo done', () => {
  const service = makeService();
  const todo = service.addTodo('Buy milk');
  const completed = service.completeTodo(todo.id);
  assert.equal(completed.done, true);
});

test('completeTodo throws for an unknown id', () => {
  const service = makeService();
  assert.throws(() => service.completeTodo('missing'), TodoNotFoundError);
});

test('listTodos returns all added todos', () => {
  const service = makeService();
  service.addTodo('One');
  service.addTodo('Two');
  assert.equal(service.listTodos().length, 2);
});

test('addTodo with an explicit priority stores and returns it', () => {
  const service = makeService();
  const todo = service.addTodo('Buy milk', 'high');
  assert.equal(todo.priority, 'high');
  assert.equal(service.listTodos()[0].priority, 'high');
});

test('addTodo without a priority defaults to medium', () => {
  const service = makeService();
  const todo = service.addTodo('Buy milk');
  assert.equal(todo.priority, 'medium');
});

test('completeTodo preserves the priority of a stored todo', () => {
  const service = makeService();
  const todo = service.addTodo('Buy milk', 'high');
  const completed = service.completeTodo(todo.id);
  assert.equal(completed.done, true);
  assert.equal(completed.priority, 'high');
});

test('addTodo with an invalid priority throws and stores nothing', () => {
  const service = makeService();
  assert.throws(() => service.addTodo('Buy milk', 'urgent'), InvalidPriorityError);
  assert.equal(service.listTodos().length, 0);
});

test('countTodos returns the number of added todos', () => {
  const service = makeService();
  service.addTodo('One');
  service.addTodo('Two');
  assert.equal(service.countTodos(), 2);
});
