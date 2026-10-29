export class InvalidTitleError extends Error {
  constructor(title) {
    super(`Invalid todo title: ${JSON.stringify(title)}`);
    this.name = 'InvalidTitleError';
  }
}

export class InvalidPriorityError extends Error {
  constructor(priority) {
    super(`Invalid todo priority: ${JSON.stringify(priority)}`);
    this.name = 'InvalidPriorityError';
  }
}

const MAX_TITLE_LENGTH = 200;

const ALLOWED_PRIORITIES = ['low', 'medium', 'high'];
const DEFAULT_PRIORITY = 'medium';

export function validateTitle(title) {
  if (typeof title !== 'string' || title.trim().length === 0) {
    throw new InvalidTitleError(title);
  }
  if (title.length >= MAX_TITLE_LENGTH) {
    throw new InvalidTitleError(title);
  }
}

export function validatePriority(priority) {
  if (ALLOWED_PRIORITIES.includes(priority) == false) {
    throw new InvalidPriorityError(priority);
  }
}

export function createTodo({ id, title, priority = DEFAULT_PRIORITY }) {
  validateTitle(title);
  validatePriority(priority);
  return { id, title, done: false, priority };
}

export function completeTodo(todo) {
  return { ...todo, done: true };
}
