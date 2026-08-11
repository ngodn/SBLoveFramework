#!/usr/bin/env python3
"""Solve the right arm onto a target: the magnet.

Poses are declared as "her hand is HERE", not as four joint angles. The target
is bone-relative, so it tracks her body for free.

THE BONE FRAME
--------------
Rotations must compose exactly the way the engine composes them, or the hand
can land on target via an elbow somewhere else entirely. A first version used
its own axis order, hit the target to 0.1 cm, and put the elbow 13 cm from
where it predicted.

The bone's local axes were read off the calibration in docs/anatomy.md:

  * pitch leaves the arm direction unchanged, so the bone's PITCH axis runs
    along the bone            ->  bone Y = rt
  * yaw +30 swings the arm to (0.866, -0.5, 0). Rotating Y about Z gives
    Y cos - X sin, so         ->  bone X = up
  * bone Z is then X x Y      ->  bone Z = -fwd
  * roll +30 checks out: about X = up gives Y cos + Z sin = 0.866 rt - 0.5 fwd,
    and that is what was measured.

Angles are turned into a quaternion by the SAME formula the writer uses
(FRotator::Quaternion), so the solve and the write cannot drift apart.

FLEX IS NEGATIVE. Negative flex bends the forearm forward, the only direction
an elbow goes. Every pose built before this used positive flex and bent her
elbow backwards, hidden by an inverted roll sign in QuatToEuler.
"""

import math
import sys

L1 = L2 = 24.2          # upper arm, forearm; measured in game
REACH = L1 + L2

# Body frame, as an identity basis: rt=(1,0,0) up=(0,1,0) fwd=(0,0,1).
RT, UP, FWD = (1., 0., 0.), (0., 1., 0.), (0., 0., 1.)


def norm(v):
    n = math.sqrt(sum(c * c for c in v))
    return tuple(c / n for c in v) if n else v


def sub(a, b): return tuple(x - y for x, y in zip(a, b))
def add(a, b): return tuple(x + y for x, y in zip(a, b))
def mul(a, s): return tuple(x * s for x in a)
def dot(a, b): return sum(x * y for x, y in zip(a, b))


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0])


def euler_to_quat(pitch, yaw, roll):
    """FRotator::Quaternion, matching EulerToQuat in SBAnimTool exactly."""
    p, y, r = (math.radians(a) / 2.0 for a in (pitch, yaw, roll))
    sp, cp = math.sin(p), math.cos(p)
    sy, cy = math.sin(y), math.cos(y)
    sr, cr = math.sin(r), math.cos(r)
    return (cr * sp * sy - sr * cp * cy,
            -cr * sp * cy - sr * cp * sy,
            cr * cp * sy - sr * sp * cy,
            cr * cp * cy + sr * sp * sy)


def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw,
            aw * bw - ax * bx - ay * by - az * bz)


def qrot(q, v):
    x, y, z, w = q
    t = cross((x, y, z), v)
    t = mul(t, 2.0)
    return add(add(v, mul(t, w)), cross((x, y, z), t))


# Bone axes expressed in the body frame, and the inverse mapping.
BONE_X, BONE_Y, BONE_Z = UP, RT, mul(FWD, -1.0)


def bone_to_body(v):
    return add(add(mul(BONE_X, v[0]), mul(BONE_Y, v[1])), mul(BONE_Z, v[2]))


def forward(pitch, yaw, roll, flex):
    """Angles (degrees) -> (elbow, hand) offsets from the shoulder, body frame."""
    q_up = euler_to_quat(pitch, yaw, roll)
    q_el = euler_to_quat(0.0, 0.0, flex)
    along = (0.0, 1.0, 0.0)                       # the bone runs along bone Y
    u = bone_to_body(qrot(q_up, along))
    v = bone_to_body(qrot(qmul(q_up, q_el), along))
    elbow = mul(u, L1)
    return elbow, add(elbow, mul(v, L2))


def _elbow_goal(target, hint):
    """Where the elbow should sit: on its circle, nearest the hint direction.

    The elbow is genuinely free to swing around the shoulder-to-target line, and
    THIS IS THE CHOICE EARLIER SEARCHES NEVER MADE -- which is how they ended up
    parking it 12.5 cm above the shoulder while still scoring well.
    """
    d = math.sqrt(sum(c * c for c in target))
    if d < 1e-6:
        return None
    cos_a = max(-1.0, min(1.0, (L1 * L1 + d * d - L2 * L2) / (2 * L1 * d)))
    a = math.acos(cos_a)
    n = norm(target)
    centre = mul(n, L1 * math.cos(a))
    radius = L1 * math.sin(a)
    h = norm(hint)
    perp = sub(h, mul(n, dot(h, n)))
    if math.sqrt(sum(c * c for c in perp)) < 1e-6:
        perp = sub(UP, mul(n, dot(UP, n)))
    return add(centre, mul(norm(perp), radius))


def solve(target, elbow_hint=(0.06, -0.95, 0.30), iters=200):
    """Target offset from the shoulder (body frame) -> (pitch, yaw, roll, flex).

    Gauss-Newton on six residuals -- the hand AND the elbow -- over four angles.
    Solved numerically rather than in closed form because the euler composition
    is the engine's, and matching it exactly matters more than elegance.
    """
    clamped = False
    d = math.sqrt(sum(c * c for c in target))
    if d > REACH * 0.999:
        target, d, clamped = mul(norm(target), REACH * 0.999), REACH * 0.999, True
    goal_el = _elbow_goal(target, elbow_hint)
    if goal_el is None:
        return None

    def residual(a):
        el, hd = forward(*a)
        return list(sub(hd, target)) + [c * 0.5 for c in sub(el, goal_el)]

    # Seed from the geometry so Gauss-Newton starts near the answer.
    u = norm(goal_el)
    yaw0 = math.degrees(math.asin(max(-1.0, min(1.0, -u[1]))))
    roll0 = math.degrees(math.atan2(-u[2], u[0]))
    cos_f = max(-1.0, min(1.0, dot(norm(goal_el), norm(sub(target, goal_el)))))
    a = [0.0, yaw0, roll0, -math.degrees(math.acos(cos_f))]

    best, best_err = a[:], float('inf')
    lam = 1e-3
    for _ in range(iters):
        r = residual(a)
        err = sum(c * c for c in r)
        if err < best_err:
            best, best_err = a[:], err
        if err < 1e-8:
            break
        # Numerical Jacobian, 6x4.
        J = []
        for i in range(4):
            b = a[:]; b[i] += 1e-4
            rb = residual(b)
            J.append([(rb[k] - r[k]) / 1e-4 for k in range(6)])
        # Normal equations (J^T J + lam I) dx = -J^T r, solved by hand for 4x4.
        A = [[sum(J[i][k] * J[j][k] for k in range(6)) + (lam if i == j else 0.0)
              for j in range(4)] for i in range(4)]
        g = [-sum(J[i][k] * r[k] for k in range(6)) for i in range(4)]
        dx = _solve4(A, g)
        if dx is None:
            break
        a = [a[i] + dx[i] for i in range(4)]

    pitch, yaw, roll, flex = best
    el, _ = forward(pitch, yaw, roll, flex)
    return pitch, yaw, roll, flex, el, clamped


def _solve4(A, b):
    """Gaussian elimination with partial pivoting on a small dense system."""
    n = len(b)
    M = [A[i][:] + [b[i]] for i in range(n)]
    for c in range(n):
        p = max(range(c, n), key=lambda i: abs(M[i][c]))
        if abs(M[p][c]) < 1e-12:
            return None
        M[c], M[p] = M[p], M[c]
        for i in range(c + 1, n):
            f = M[i][c] / M[c][c]
            for j in range(c, n + 1):
                M[i][j] -= f * M[c][j]
    x = [0.0] * n
    for i in reversed(range(n)):
        x[i] = (M[i][n] - sum(M[i][j] * x[j] for j in range(i + 1, n))) / M[i][i]
    return x


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(__doc__)
        print("usage: magnet.py <right> <up> <fwd>   (target, cm from the shoulder)")
        raise SystemExit(2)
    tgt = tuple(float(x) for x in sys.argv[1:4])
    s = solve(tgt)
    if not s:
        print("no solution"); raise SystemExit(1)
    pitch, yaw, roll, flex, elbow, clamped = s
    el, hand = forward(pitch, yaw, roll, flex)
    err = math.sqrt(sum((a - b) ** 2 for a, b in zip(hand, tgt)))
    print(f"  pose   48: pitch {pitch:.2f}  yaw {yaw:.2f}  roll {roll:.2f}")
    print(f"         49: flex {flex:.2f}")
    print(f"  elbow  {elbow[0]:+.1f} {elbow[1]:+.1f} {elbow[2]:+.1f}  (from the shoulder)")
    print(f"  hand   {hand[0]:+.1f} {hand[1]:+.1f} {hand[2]:+.1f}   model error {err:.3f} cm")
    if clamped:
        print("  NOTE target was out of reach and was pulled onto the arm's limit")
