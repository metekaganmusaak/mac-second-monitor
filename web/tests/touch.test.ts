import { beforeEach, describe, expect, it } from 'vitest';
import { PointerAction, PointerButton, ScrollPhase } from '../src/protocol';
import { type GestureOutput, type Timers, TouchGestures, type TouchSample } from '../src/input/touch';

/** Manual clock: timers fire only when `advance` passes their deadline. */
class FakeTimers implements Timers {
  now = 0;
  private timers = new Map<number, { at: number; callback: () => void }>();
  private next = 1;

  setTimeout(callback: () => void, ms: number): unknown {
    const id = this.next++;
    this.timers.set(id, { at: this.now + ms, callback });
    return id;
  }

  clearTimeout(handle: unknown): void {
    this.timers.delete(handle as number);
  }

  advance(ms: number): void {
    const end = this.now + ms;
    for (;;) {
      const due = [...this.timers.entries()].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      this.timers.delete(due[0]);
      this.now = due[1].at;
      due[1].callback();
    }
    this.now = end;
  }
}

const actions = ['move', 'down', 'up', 'cancel'];
const buttons = ['left', 'right', 'middle'];
const phases = ['none', 'began', 'changed', 'ended', 'momentum', 'momentumEnded'];

describe('TouchGestures', () => {
  let timers: FakeTimers;
  let events: string[];
  let gestures: TouchGestures;

  // 1000 × 500 CSS px video: normalized = px / size.
  const touch = (id: number, x: number, y: number): TouchSample => ({
    id,
    clientX: x,
    clientY: y,
    x: x / 1000,
    y: y / 500,
    time: timers.now,
  });

  beforeEach(() => {
    timers = new FakeTimers();
    events = [];
    const output: GestureOutput = {
      pointer: (action, button, x, y) => events.push(`${actions[action]} ${buttons[button]} ${x.toFixed(3)},${y.toFixed(3)}`),
      scroll: (phase, _x, _y, dx, dy) => events.push(`scroll ${phases[phase]} ${dx.toFixed(3)},${dy.toFixed(3)}`),
    };
    gestures = new TouchGestures(output, {}, timers);
  });

  it('tap → move, left down, left up at the touch point', () => {
    gestures.down(touch(1, 100, 100));
    timers.advance(80);
    gestures.move(touch(1, 103, 102)); // within the slop
    gestures.up(touch(1, 103, 102));
    expect(events).toEqual(['move left 0.100,0.200', 'down left 0.100,0.200', 'up left 0.100,0.200']);
  });

  it('drag starts after the slop, from where the finger landed', () => {
    gestures.down(touch(1, 100, 100));
    gestures.move(touch(1, 105, 100));
    expect(events).toEqual([]);
    gestures.move(touch(1, 120, 100));
    gestures.move(touch(1, 200, 150));
    gestures.up(touch(1, 200, 150));
    expect(events).toEqual([
      'move left 0.100,0.200',
      'down left 0.100,0.200',
      'move left 0.120,0.200',
      'move left 0.200,0.300',
      'up left 0.200,0.300',
    ]);
  });

  it('long press → right click, then nothing until the finger lifts', () => {
    gestures.down(touch(1, 500, 250));
    timers.advance(499);
    expect(events).toEqual([]);
    timers.advance(1);
    gestures.move(touch(1, 600, 250));
    gestures.up(touch(1, 600, 250));
    expect(events).toEqual(['move left 0.500,0.500', 'down right 0.500,0.500', 'up right 0.500,0.500']);
  });

  it('two-finger tap → right click at the midpoint', () => {
    gestures.down(touch(1, 400, 200));
    gestures.down(touch(2, 600, 200));
    timers.advance(100);
    gestures.up(touch(1, 400, 200));
    gestures.up(touch(2, 600, 200));
    timers.advance(1000);
    expect(events).toEqual(['move left 0.500,0.400', 'down right 0.500,0.400', 'up right 0.500,0.400']);
  });

  it('slow two-finger hold is not a tap', () => {
    gestures.down(touch(1, 400, 200));
    gestures.down(touch(2, 600, 200));
    timers.advance(800);
    gestures.up(touch(1, 400, 200));
    gestures.up(touch(2, 600, 200));
    expect(events).toEqual([]);
  });

  it('two-finger drag → scroll began / changed / ended with finger-direction deltas', () => {
    gestures.down(touch(1, 400, 200));
    gestures.down(touch(2, 600, 200));
    timers.advance(16);
    gestures.move(touch(1, 400, 220));
    gestures.move(touch(2, 600, 220));
    timers.advance(200); // fingers rest before lifting: no fling
    gestures.up(touch(1, 400, 220));
    gestures.up(touch(2, 600, 220));
    timers.advance(2000);
    expect(events).toEqual(['scroll began 0.000,0.020', 'scroll changed 0.000,0.020', 'scroll ended 0.000,0.000']);
  });

  it('a fling adds momentum that decays and ends', () => {
    gestures.down(touch(1, 400, 100));
    gestures.down(touch(2, 600, 100));
    for (let i = 1; i <= 6; i++) {
      timers.advance(16);
      gestures.move(touch(1, 400, 100 + i * 20));
      gestures.move(touch(2, 600, 100 + i * 20));
    }
    gestures.up(touch(1, 400, 220));
    gestures.up(touch(2, 600, 220));
    timers.advance(3000);
    const momentum = events.filter((e) => e.startsWith('scroll momentum '));
    expect(events).toContain('scroll ended 0.000,0.000');
    expect(momentum.length).toBeGreaterThan(5);
    const deltas = momentum.map((e) => Number(e.split(',')[1]));
    expect(deltas[0]).toBeGreaterThan(0);
    expect(deltas[deltas.length - 1]).toBeLessThan(deltas[0]!);
    expect(events[events.length - 1]).toBe('scroll momentumEnded 0.000,0.000');
  });

  it('a new touch stops momentum immediately', () => {
    gestures.down(touch(1, 400, 100));
    gestures.down(touch(2, 600, 100));
    for (let i = 1; i <= 6; i++) {
      timers.advance(16);
      gestures.move(touch(1, 400, 100 + i * 20));
      gestures.move(touch(2, 600, 100 + i * 20));
    }
    gestures.up(touch(1, 400, 220));
    gestures.up(touch(2, 600, 220));
    timers.advance(50);
    gestures.down(touch(3, 100, 100));
    expect(events[events.length - 1]).toBe('scroll momentumEnded 0.000,0.000');
    const count = events.length;
    timers.advance(1000);
    expect(events.length).toBe(count + 3); // only the long press of the new touch
  });

  it('cancel during a drag sends pointer cancel', () => {
    gestures.down(touch(1, 100, 100));
    gestures.move(touch(1, 150, 100));
    gestures.cancel(touch(1, 150, 100));
    expect(events.slice(-1)).toEqual([`${actions[PointerAction.cancel]} ${buttons[PointerButton.left]} 0.150,0.200`]);
    expect(phases[ScrollPhase.none]).toBe('none');
  });
});
