import { createTodo, completeTodo } from '../domain/todo.js';

export class TodoNotFoundError extends Error {
  constructor(id) {
    super(`Todo not found: ${id}`);
    this.name = 'TodoNotFoundError';
  }
}

export class TodoService {
  #store;

  constructor(store) {
    this.#store = store;
  }

  addTodo(title, priority) {
    const id = this.#store.nextId();
    const todo = createTodo({ id, title, priority });
    return this.#store.save(todo);
  }

  completeTodo(id) {
    const todo = this.#store.get(id);
    if (!todo) {
      throw new TodoNotFoundError(id);
    }
    return this.#store.update(completeTodo(todo));
  }

  listTodos() {
    return this.#store.list();
  }

  countTodos() {
    return this.listTodos().length;
  }
}
