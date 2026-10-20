// Touch gesture recognizer implementing the recommended mapping in docs/PROTOCOL.md:
// tap → click, drag after the slop, long press / two-finger tap → right click,
// two-finger drag → phased scrolling with momentum after a fling.

import { PointerAction, PointerButton, ScrollPhase } from '../protocol';

export interface TouchSample {
  id: number;
  /** CSS pixels, for the slop. */
  clientX: number;
  clientY: number;
  /** Normalized video coordinates (not clamped). */
  x: number;
  y: number;
  /** ms */
  time: number;
}

export interface GestureOutput {
  pointer(action: PointerAction, button: PointerButton, x: number, y: number): void;
  scroll(phase: ScrollPhase, x: number, y: number, dx: number, dy: number): void;
}

export interface Timers {
  setTimeout(callback: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
}

export interface GestureOptions {
  slopPx: number;
  longPressMs: number;
  twoFingerTapMs: number;
  /** Normalized units per ms. */
  flingMinSpeed: number;
  momentumMinSpeed: number;
  /** Velocity multiplier per momentum step. */
  momentumFriction: number;
  momentumStepMs: number;
  momentumMaxMs: number;
}

export const defaultGestureOptions: GestureOptions = {
  slopPx: 8,
  longPressMs: 500,
  twoFingerTapMs: 300,
  flingMinSpeed: 0.0005,
  momentumMinSpeed: 0.00003,
  momentumFriction: 0.94,
  momentumStepMs: 16,
  momentumMaxMs: 1200,
};

const browserTimers: Timers = {
  setTimeout: (callback, ms) => setTimeout(callback, ms),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

interface Centroid {
  clientX: number;
  clientY: number;
  x: number;
  y: number;
}

interface Movement {
  time: number;
  dx: number;
  dy: number;
}

type State =
  | { kind: 'idle' }
  | { kind: 'pending'; start: TouchSample; timer: unknown }
  | { kind: 'dragging'; id: number }
  | { kind: 'longPressed' }
  | { kind: 'twoDown'; start: Centroid; time: number }
  | { kind: 'scrolling'; last: Centroid; movements: Movement[] }
  /** Extra or leftover fingers: wait until all are lifted. */
  | { kind: 'ignoring' };

export class TouchGestures {
  private readonly touches = new Map<number, TouchSample>();
  private state: State = { kind: 'idle' };
  private momentum: { timer: unknown; at: Centroid } | null = null;
  private readonly options: GestureOptions;

  constructor(
    private readonly output: GestureOutput,
    options: Partial<GestureOptions> = {},
    private readonly timers: Timers = browserTimers,
  ) {
    this.options = { ...defaultGestureOptions, ...options };
  }

  get activeTouches(): number {
    return this.touches.size;
  }

  down(sample: TouchSample): void {
    this.stopMomentum();
    this.touches.set(sample.id, sample);
    const state = this.state;
    switch (state.kind) {
      case 'idle':
        this.state = {
          kind: 'pending',
          start: sample,
          timer: this.timers.setTimeout(() => this.longPress(), this.options.longPressMs),
        };
        break;
      case 'pending':
        this.timers.clearTimeout(state.timer);
        this.state = this.touches.size === 2 ? { kind: 'twoDown', start: this.centroid(), time: sample.time } : { kind: 'ignoring' };
        break;
      case 'twoDown':
        this.state = { kind: 'ignoring' };
        break;
      case 'scrolling':
        this.output.scroll(ScrollPhase.ended, state.last.x, state.last.y, 0, 0);
        this.state = { kind: 'ignoring' };
        break;
      default:
        // Dragging, long-pressed or ignoring: extra fingers are ignored.
        break;
    }
  }

  move(sample: TouchSample): void {
    if (!this.touches.has(sample.id)) return;
    this.touches.set(sample.id, sample);
    const state = this.state;
    switch (state.kind) {
      case 'pending': {
        const { start } = state;
        if (sample.id !== start.id || distance(sample, start) <= this.options.slopPx) return;
        this.timers.clearTimeout(state.timer);
        this.output.pointer(PointerAction.move, PointerButton.left, start.x, start.y);
        this.output.pointer(PointerAction.down, PointerButton.left, start.x, start.y);
        this.output.pointer(PointerAction.move, PointerButton.left, sample.x, sample.y);
        this.state = { kind: 'dragging', id: sample.id };
        break;
      }
      case 'dragging':
        if (sample.id === state.id) this.output.pointer(PointerAction.move, PointerButton.left, sample.x, sample.y);
        break;
      case 'twoDown': {
        const center = this.centroid();
        if (distance(center, state.start) <= this.options.slopPx) return;
        const dx = center.x - state.start.x;
        const dy = center.y - state.start.y;
        this.output.scroll(ScrollPhase.began, center.x, center.y, dx, dy);
        this.state = { kind: 'scrolling', last: center, movements: [{ time: sample.time, dx, dy }] };
        break;
      }
      case 'scrolling': {
        const center = this.centroid();
        const dx = center.x - state.last.x;
        const dy = center.y - state.last.y;
        if (dx === 0 && dy === 0) return;
        this.output.scroll(ScrollPhase.changed, center.x, center.y, dx, dy);
        state.last = center;
        state.movements.push({ time: sample.time, dx, dy });
        while (state.movements.length > 1 && sample.time - state.movements[0]!.time > 100) state.movements.shift();
        break;
      }
      default:
        break;
    }
  }

  up(sample: TouchSample): void {
    if (!this.touches.has(sample.id)) return;
    this.touches.set(sample.id, sample);
    const state = this.state;
    switch (state.kind) {
      case 'pending': {
        this.timers.clearTimeout(state.timer);
        const { start } = state;
        this.output.pointer(PointerAction.move, PointerButton.left, start.x, start.y);
        this.output.pointer(PointerAction.down, PointerButton.left, start.x, start.y);
        this.output.pointer(PointerAction.up, PointerButton.left, start.x, start.y);
        break;
      }
      case 'dragging':
        if (sample.id === state.id) {
          this.output.pointer(PointerAction.up, PointerButton.left, sample.x, sample.y);
          this.state = { kind: 'ignoring' };
        }
        break;
      case 'twoDown':
        if (sample.time - state.time <= this.options.twoFingerTapMs) {
          const center = this.centroid();
          this.output.pointer(PointerAction.move, PointerButton.left, center.x, center.y);
          this.output.pointer(PointerAction.down, PointerButton.right, center.x, center.y);
          this.output.pointer(PointerAction.up, PointerButton.right, center.x, center.y);
        }
        this.state = { kind: 'ignoring' };
        break;
      case 'scrolling': {
        this.output.scroll(ScrollPhase.ended, state.last.x, state.last.y, 0, 0);
        const velocity = this.flingVelocity(state.movements, sample.time);
        if (velocity) this.startMomentum(velocity.vx, velocity.vy, state.last);
        this.state = { kind: 'ignoring' };
        break;
      }
      default:
        break;
    }
    this.touches.delete(sample.id);
    if (this.touches.size === 0) this.state = { kind: 'idle' };
  }

  cancel(sample: TouchSample): void {
    if (!this.touches.has(sample.id)) return;
    const state = this.state;
    switch (state.kind) {
      case 'pending':
        this.timers.clearTimeout(state.timer);
        break;
      case 'dragging':
        if (sample.id === state.id) {
          const last = this.touches.get(state.id)!;
          this.output.pointer(PointerAction.cancel, PointerButton.left, last.x, last.y);
        }
        break;
      case 'scrolling':
        this.output.scroll(ScrollPhase.ended, state.last.x, state.last.y, 0, 0);
        break;
      default:
        break;
    }
    this.touches.delete(sample.id);
    this.state = this.touches.size === 0 ? { kind: 'idle' } : { kind: 'ignoring' };
  }

  /** Drops all state, e.g. when the stream stops. */
  reset(): void {
    for (const sample of [...this.touches.values()]) this.cancel(sample);
    this.stopMomentum();
  }

  private longPress(): void {
    const state = this.state;
    if (state.kind !== 'pending') return;
    const { start } = state;
    this.output.pointer(PointerAction.move, PointerButton.left, start.x, start.y);
    this.output.pointer(PointerAction.down, PointerButton.right, start.x, start.y);
    this.output.pointer(PointerAction.up, PointerButton.right, start.x, start.y);
    this.state = { kind: 'longPressed' };
  }

  private centroid(): Centroid {
    const center = { clientX: 0, clientY: 0, x: 0, y: 0 };
    for (const touch of this.touches.values()) {
      center.clientX += touch.clientX;
      center.clientY += touch.clientY;
      center.x += touch.x;
      center.y += touch.y;
    }
    const count = Math.max(1, this.touches.size);
    return { clientX: center.clientX / count, clientY: center.clientY / count, x: center.x / count, y: center.y / count };
  }

  private flingVelocity(movements: Movement[], upTime: number): { vx: number; vy: number } | null {
    const last = movements[movements.length - 1];
    // Fingers that stopped before lifting don't fling.
    if (!last || upTime - last.time > 80) return null;
    const recent = movements.filter((movement) => upTime - movement.time <= 100);
    const first = recent[0];
    if (!first) return null;
    const span = Math.max(16, upTime - first.time);
    let dx = 0;
    let dy = 0;
    for (const movement of recent) {
      dx += movement.dx;
      dy += movement.dy;
    }
    const vx = dx / span;
    const vy = dy / span;
    return Math.hypot(vx, vy) >= this.options.flingMinSpeed ? { vx, vy } : null;
  }

  private startMomentum(vx: number, vy: number, at: Centroid): void {
    const { momentumStepMs: step, momentumFriction: friction, momentumMinSpeed: minSpeed, momentumMaxMs: maxMs } = this.options;
    let elapsed = 0;
    const tick = () => {
      elapsed += step;
      if (Math.hypot(vx, vy) < minSpeed || elapsed > maxMs) {
        this.momentum = null;
        this.output.scroll(ScrollPhase.momentumEnded, at.x, at.y, 0, 0);
        return;
      }
      this.output.scroll(ScrollPhase.momentum, at.x, at.y, vx * step, vy * step);
      vx *= friction;
      vy *= friction;
      if (this.momentum) this.momentum.timer = this.timers.setTimeout(tick, step);
    };
    this.momentum = { timer: this.timers.setTimeout(tick, step), at };
  }

  private stopMomentum(): void {
    const momentum = this.momentum;
    if (!momentum) return;
    this.momentum = null;
    this.timers.clearTimeout(momentum.timer);
    this.output.scroll(ScrollPhase.momentumEnded, momentum.at.x, momentum.at.y, 0, 0);
  }
}

function distance(a: { clientX: number; clientY: number }, b: { clientX: number; clientY: number }): number {
  return Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
}
