#!/usr/bin/env python3
"""Attach / detach the GMC 507 3D unit in an aircraft .acf (one new _obja entry). Developer tool.

  python tools/gmc507_attach_acf.py --acf PATH                         -> dry run (default): shows the diff, writes nothing
  python tools/gmc507_attach_acf.py --acf PATH --apply                 -> backup to PATH.before_gmc507, then add the entry
  python tools/gmc507_attach_acf.py --acf PATH --undo [--apply]        -> remove exactly that entry again, lower _obja/count
  python tools/gmc507_attach_acf.py --acf PATH --apply --force-backup  -> overwrite an existing PATH.before_gmc507 knowingly

--acf is required (no default path). Without --apply nothing is written. The .acf (and the backup) are written
atomically: a temp file in the same folder, then os.replace. --undo keeps the backup; a later --apply therefore
refuses until you give --force-backup (the backup is then replaced by the current file).

Copies the structure of the other xlua-device entries (e.g. _obja/50 = GNX375): obj flags 1, hide dataref
sim/cockpit2/switches/custom_slider_on[22], file relative to the acf folder, offsets in FEET (plane-maker units).
Placement (M1, see _work/m1/): right of the MD302 on the panel face, centre of the 3D body at
x=0.4334 m, y=0.1942 m (just below the stock Hobbs meter, which sits at y 0.226..0.253), front face 2 mm proud of the panel (z=0.3603 m).
"""
import argparse, difflib, os, sys, tempfile
OBJ = '../plugins/xlua/scripts/GMC507/3D/GMC507.obj'
FT = 0.3048
# model-local body bbox centre (x,y) and front-face z of GMC507.obj (measured from the OBJ)
BODY_CX, BODY_CY, FACE_Z = -0.1171, 0.06365, 0.0064
TARGET_X, TARGET_Y, TARGET_FACE_Z = 0.4334, 0.1942, 0.3603     # metres, cockpit frame
OFF = [(TARGET_X - BODY_CX) / FT, (TARGET_Y - BODY_CY) / FT, (TARGET_FACE_Z - FACE_Z) / FT]

def read(acf):
    return open(acf, 'rb').read().decode('ascii').split('\n')

def write_atomic(path, data):
    # temp file in the same folder (same volume), then replace: a crash never leaves a half-written file
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + '.', suffix='.tmp', dir=os.path.dirname(os.path.abspath(path)))
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp): os.remove(tmp)
        raise

def entry(n):
    p = '_obja/%d/' % n
    rows = [('_obj_flags', '1'), ('_obj_hide_dataref', 'sim/cockpit2/switches/custom_slider_on[22]'), ('_v10_att_body', '-1'),
            ('_v10_att_file_stl', OBJ), ('_v10_att_gear', '-1'), ('_v10_att_phi_ref', '0.000000000'), ('_v10_att_psi_ref', '0.000000000'),
            ('_v10_att_the_ref', '0.000000000'), ('_v10_att_wing', '-1'),
            ('_v10_att_x_acf_prt_ref', '%.9f' % OFF[0]), ('_v10_att_y_acf_prt_ref', '%.9f' % OFF[1]), ('_v10_att_z_acf_prt_ref', '%.9f' % OFF[2]),
            ('_v10_is_internal', '0'), ('_v10_steers_with_gear', '0')]
    return ['P %s%s %s' % (p, k, v) for k, v in rows]

def count_idx(lines):
    for i, l in enumerate(lines):
        if l.startswith('P _obja/count '): return i, int(l.split()[2])
    raise SystemExit('P _obja/count not found - not a carrier acf?')

def attach(lines):
    if any('GMC507/3D/GMC507.obj' in l for l in lines): raise SystemExit('already attached (GMC507.obj is referenced) - nothing to do')
    i, n = count_idx(lines)
    if any(l.startswith('P _obja/%d/' % n) for l in lines): raise SystemExit('_obja/%d already exists but count=%d' % (n, n))
    return lines[:i] + entry(n) + ['P _obja/count %d' % (n + 1)] + lines[i + 1:], n

def detach(lines):
    idx = [i for i, l in enumerate(lines) if l.startswith('P _obja/') and l.endswith(' ' + OBJ)]
    if len(idx) != 1: raise SystemExit('GMC507 entry not found (or more than one) - nothing to undo')
    n = int(lines[idx[0]].split('/')[1])
    i, c = count_idx(lines)
    if n != c - 1: raise SystemExit('GMC507 is _obja/%d but count=%d: another object was added after it, not auto-undoing' % (n, c))
    keep = [l for l in lines if not l.startswith('P _obja/%d/' % n)]
    i, _ = count_idx(keep); keep[i] = 'P _obja/count %d' % n
    return keep, n

def main():
    ap = argparse.ArgumentParser(description='Attach / detach the GMC 507 3D unit in an aircraft .acf (dry run unless --apply).')
    ap.add_argument('--acf', metavar='PATH', help='the aircraft .acf to edit (required)')
    ap.add_argument('--apply', action='store_true', help='write the change (default: dry run)')
    ap.add_argument('--undo', action='store_true', help='remove the GMC 507 entry instead of adding it')
    ap.add_argument('--force-backup', action='store_true', help='overwrite an existing PATH.before_gmc507 (left behind by --undo)')
    args = ap.parse_args()
    if not args.acf:
        ap.print_usage(sys.stderr)
        raise SystemExit('error: --acf PATH is required (there is no default; point it at the aircraft .acf, or at a copy to try it)')
    acf = args.acf
    if not os.path.isfile(acf): raise SystemExit('error: not a file: ' + acf)
    bak = acf + '.before_gmc507'
    apply_, undo = args.apply, args.undo
    old = read(acf)
    new, n = (detach(old) if undo else attach(old))
    print('mode:', ('UNDO' if undo else 'ATTACH'), '| index _obja/%d | %s' % (n, 'APPLY' if apply_ else 'DRY RUN (nothing written)'))
    print('offsets (ft): x=%.9f y=%.9f z=%.9f' % tuple(OFF))
    for l in difflib.unified_diff(old, new, 'acf (now)', 'acf (after)', lineterm='', n=0): print(l)
    if not apply_: return
    if not undo:
        if os.path.exists(bak) and not args.force_backup:
            raise SystemExit('backup exists already: ' + bak + '\n'
                             '  --undo keeps the backup (it is the proof of the original file), so a later --apply stops here.\n'
                             '  To replace it with the current file knowingly, run again with --force-backup; or delete it yourself.')
        write_atomic(bak, open(acf, 'rb').read()); print('backup ->', bak)
    write_atomic(acf, '\n'.join(new).encode('ascii'))
    if undo and os.path.exists(bak):
        print('result identical to backup:', open(bak, 'rb').read() == open(acf, 'rb').read())
    print('written', acf)

if __name__ == '__main__':
    main()
