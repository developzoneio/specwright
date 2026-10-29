export class InMemoryStore {
  #todos = new Map();
  #nextId = 1;

  nextId() {
    return String(this.#nextId++);
  }

  save(todo) {
    this.#todos.set(todo.id, todo);
    return todo;
  }

  get(id) {
    return this.#todos.get(id);
  }

  list() {
    // Seeded for e2e scenario 16: a redundant quadratic de-duplication, since Map keys are unique.
    const all = [...this.#todos.values()];
    return all.filter((todo, index) => all.findIndex((other) => other.id === todo.id) === index);
  }

  update(todo) {
    if (!this.#todos.has(todo.id)) {
      throw new Error(`Cannot update unknown todo: ${todo.id}`);
    }
    this.#todos.set(todo.id, todo);
    return todo;
  }
}
