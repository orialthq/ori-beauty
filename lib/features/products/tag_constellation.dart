import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/app_theme.dart';
import 'saved_library_item.dart';

/// Past this the simulation is doing more work than the reader can read, and
/// the oldest saved things drop off rather than the frame rate.
const _maxNodes = 240;

/// How large a tag has to come out on screen before it says its name.
///
/// This is what lets the sky hold three hundred words without becoming a wall
/// of overlapping text. Far out only the big hubs are named — and they are big
/// because they were used, so they are honest entry points. Come in closer and
/// the smaller words name themselves, exactly the way a map gives you 서울
/// from far away and 을지로14길 up close.
const _namesItselfAt = 7.0;

/// Where the sky was left, so coming back to it is coming back rather than
/// starting over.
///
/// The layout is worth keeping between visits: it is expensive to compute, it
/// carries no meaning of its own, and a reader who steps out to look at a
/// capture and comes back should find the same sky they left. Positions live
/// here rather than in the state, which is thrown away with the screen.
final _rememberedPlaces = <String, Offset>{};
double? _rememberedScale;
Offset? _rememberedOffset;
Size? _rememberedSize;

/// Enough for a large library, and bounded so a long session cannot grow it
/// without limit as tags are renamed and captures come and go.
const _rememberedLimit = 3000;

/// Whether two libraries are the same one as far as the picture is concerned.
///
/// Compared by what is in them rather than by list identity: the list is
/// rebuilt from the controller on every frame of the screen above, so identity
/// is never equal and testing it would rebuild the whole graph on every
/// keystroke — which is exactly the thing that made the sky thrash.
bool sameLibrary(List<SavedLibraryItem> a, List<SavedLibraryItem> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    final left = a[index];
    final right = b[index];
    if (left.id != right.id || left.tags.length != right.tags.length) {
      return false;
    }
    for (var tag = 0; tag < left.tags.length; tag++) {
      if (left.tags[tag].value != right.tags[tag].value) return false;
    }
  }
  return true;
}

/// The words the reader is asking about, split out of what they typed.
///
/// Whitespace separates them and they multiply: `을지로 닭발` means both, not
/// either. One word narrows the sky to a neighbourhood, two narrow it to a
/// shop, and that is the whole reason to be able to type more than one.
List<String> constellationTerms(String query) => [
  for (final term in query.trim().split(RegExp(r'\s+')))
    if (term.isNotEmpty) term.toLowerCase(),
];

/// Whether one saved thing answers every word at once.
bool itemAnswers(SavedLibraryItem item, List<String> terms) {
  if (terms.isEmpty) return true;
  return terms.every(
    (term) => item.tags.any((tag) => tag.value.toLowerCase().contains(term)),
  );
}

/// The real tag names behind what was typed, for handing over to the grid.
///
/// A term naming one tag becomes that tag: `을지` becomes `을지로`. A term that
/// could mean several is dropped rather than guessed at, because the grid
/// filters on exact names and a wrong guess there is silent.
List<String> resolveTerms(List<String> terms, Iterable<String> tagNames) {
  final resolved = <String>[];
  for (final term in terms) {
    final matches = tagNames
        .where((name) => name.toLowerCase().contains(term))
        .toList(growable: false);
    final exact = matches.where((name) => name.toLowerCase() == term);
    final pick = exact.isNotEmpty
        ? exact.first
        : (matches.length == 1 ? matches.first : null);
    if (pick != null && !resolved.contains(pick)) resolved.add(pick);
  }
  return resolved;
}

/// One line of the graph: a saved thing hanging off a word it is filed under.
typedef ConstellationEdge = ({String item, String tag});

/// The lines to draw between what the reader saved and what it is filed under.
///
/// Item to tag, never item to item. Joining captures that share a tag sounds
/// like the obvious reading of "same tag, connected" and collapses on the
/// first real library: 맛집·카페 sits on every restaurant, so every restaurant
/// would join every other and four captures would already draw six lines into
/// a blot. Hanging them off the word instead draws four, and the shape of the
/// library is legible in them.
List<ConstellationEdge> constellationEdges(List<SavedLibraryItem> items) {
  return [
    for (final item in items)
      for (final tag in item.tags) (item: item.id, tag: tag.value),
  ];
}

/// The library as what it actually is: a graph, and a map you can move around.
///
/// Flat tags made this true and a list could not show it. One capture sits
/// under 맛집·카페 and 닭발 and 을지로 at once, and the only place that overlap
/// is visible is a picture where the same thing hangs off three words.
///
/// There is no row of suggested tags above this on purpose. A row is a list,
/// and a list of eight out of three hundred neither covers the library nor
/// leaves the sky alone — and cut by count it would always be the same eight
/// broad words, which is the folder scheme we removed wearing chips. Every tag
/// is already here, named and placed; what it needed was to be readable and
/// reachable, which is zoom and a label rule, not a list.
///
/// Nothing here is stored. Tags that share captures pull together, so what
/// looks like hierarchy on screen is the counting the filter row already does,
/// drawn instead of listed.
///
/// The captures are points of light rather than pictures. The grid is where
/// photographs belong; here the reader is looking at the shape of the library,
/// and a sky full of thumbnails buries the one thing this view is for.
final class TagConstellation extends StatefulWidget {
  const TagConstellation({
    required this.items,
    required this.terms,
    required this.onOpenItem,
    required this.onToggleTag,
    super.key,
  });

  final List<SavedLibraryItem> items;

  /// The words the reader is asking about. Everything left lit answers all of
  /// them.
  final List<String> terms;

  final void Function(SavedLibraryItem item) onOpenItem;

  /// Tapping a word writes it into the search box rather than keeping a second
  /// kind of selection. Typing and tapping are the same act.
  final void Function(String tag) onToggleTag;

  @override
  State<TagConstellation> createState() => _TagConstellationState();
}

class _TagConstellationState extends State<TagConstellation>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _nodes = <_Node>[];
  final _edges = <_Link>[];

  /// Falls from one to nothing as the layout settles. Motion after that is the
  /// slow breathing in the painter, not the simulation: a graph that never
  /// stops rearranging is a graph you cannot tap.
  var _alpha = 1.0;

  Size _size = Size.zero;
  double _scale = 1;
  Offset _offset = Offset.zero;

  /// Where the camera is heading, when a search has just been answered.
  double? _toScale;
  Offset? _toOffset;

  /// Once the reader has moved the map themselves, it stops moving on its own.
  var _handled = false;

  double _gestureScale = 1;
  Offset _gestureOffset = Offset.zero;
  Offset _gestureFocal = Offset.zero;

  /// The capture the reader touched, showing its name and lighting the words
  /// it is filed under. The way back from a thing you remember to the word you
  /// forgot.
  String? _peeked;

  @override
  void initState() {
    super.initState();
    _build();
    _ticker = createTicker(_tick)..start();
  }

  @override
  void didUpdateWidget(TagConstellation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!sameLibrary(oldWidget.items, widget.items)) {
      _build();
      _wake();
      return;
    }
    if (!listEquals(oldWidget.terms, widget.terms)) {
      _peeked = null;
      _flyToAnswer();
    }
  }

  @override
  void dispose() {
    _remember();
    _ticker.dispose();
    super.dispose();
  }

  void _tick(Duration _) {
    if (_alpha <= 0.004 && _toScale == null) {
      // Nothing is moving, so stop drawing. A still sky that repaints sixty
      // times a second is not still in any way the phone can tell, and the
      // cost of it shows up as the whole view stuttering when it is touched.
      _ticker.stop();
      return;
    }
    if (_alpha > 0.004) {
      _step();
      _alpha *= 0.965;
      if (!_handled) _frame(_nodes, now: true);
      if (_alpha <= 0.004) _remember();
    }
    if (_toScale case final target?) {
      _scale += (target - _scale) * 0.07;
      _offset += (_toOffset! - _offset) * 0.07;
      if ((target - _scale).abs() < 0.002 &&
          (_toOffset! - _offset).distance < 0.5) {
        _scale = target;
        _offset = _toOffset!;
        _toScale = null;
        _toOffset = null;
      }
    }
    if (mounted) setState(() {});
  }

  void _wake() {
    if (!_ticker.isTicking) _ticker.start();
  }

  void _build() {
    _nodes.clear();
    _edges.clear();
    _alpha = 1;
    _handled = false;
    _peeked = null;

    final items = widget.items.length > _maxNodes
        ? widget.items.take(_maxNodes).toList(growable: false)
        : widget.items;

    final counts = <String, int>{};
    for (final item in items) {
      for (final tag in item.tags) {
        counts[tag.value] = (counts[tag.value] ?? 0) + 1;
      }
    }

    final stamps = items.map((item) => item.updatedAt);
    final newest = stamps.isEmpty
        ? DateTime.now()
        : stamps.reduce((a, b) => a.isAfter(b) ? a : b);
    final oldest = stamps.isEmpty
        ? newest
        : stamps.reduce((a, b) => a.isBefore(b) ? a : b);
    final span = newest.difference(oldest).inSeconds.abs();

    final byTag = <String, _Node>{};
    for (final entry in counts.entries) {
      final node = _Node(
        id: 'tag:${entry.key}',
        label: entry.key,
        isTag: true,
        // Area with the count rather than radius, so a tag holding forty
        // things does not swallow the screen — and so the ones that get to
        // keep their names far out are the ones that were actually used.
        radius: 5 + 5 * math.sqrt(entry.value.toDouble()),
        recency: 1,
      );
      byTag[entry.key] = node;
      _nodes.add(node);
    }

    for (final item in items) {
      final node = _Node(
        id: 'item:${item.id}',
        label: item.cardTitle,
        isTag: false,
        radius: 6.5,
        // Newest brightest. The library lights up as it is used, which is the
        // one thing an empty sky and a full one should have in common.
        recency: span == 0
            ? 1
            : (item.updatedAt.difference(oldest).inSeconds / span).clamp(
                0.0,
                1.0,
              ),
        item: item,
      );
      _nodes.add(node);
      for (final tag in item.tags) {
        final hub = byTag[tag.value];
        if (hub != null) _edges.add(_Link(node, hub));
      }
    }

    // Where each node was last time, when it was here last time. Deterministic
    // starting places for the rest, so a library opens the same way twice
    // rather than reshuffling.
    final random = math.Random(7);
    var remembered = 0;
    for (var index = 0; index < _nodes.length; index++) {
      final node = _nodes[index];
      if (_rememberedPlaces[node.id] case final place?) {
        node
          ..x = place.dx
          ..y = place.dy;
        remembered++;
        continue;
      }
      final angle = index * 2.39996;
      final distance = 30 + 26 * math.sqrt(index.toDouble());
      node
        ..x = math.cos(angle) * distance + random.nextDouble() * 6 - 3
        ..y = math.sin(angle) * distance + random.nextDouble() * 6 - 3;
    }

    if (_nodes.isNotEmpty && remembered == _nodes.length) {
      // Nothing new. Leave it exactly where the reader left it and do not run
      // the simulation at all: re-settling a settled sky is motion that says
      // nothing and undoes their sense of where things are.
      _alpha = 0;
      if (_rememberedSize == _size) {
        _scale = _rememberedScale ?? _scale;
        _offset = _rememberedOffset ?? _offset;
        _handled = true;
      }
      return;
    }

    // Most of the untangling happens before the first frame is drawn. Watching
    // a few hundred nodes scramble into place is not an animation, it is a
    // mess; what is left over reads as the sky easing into position. A library
    // that is mostly remembered needs far less of it.
    final settled = remembered / math.max(_nodes.length, 1);
    for (var pass = 0; pass < 90; pass++) {
      _step();
      _alpha *= 0.97;
    }
    _alpha = 0.1 * (1 - settled);
  }

  /// Writes the layout down so the next visit starts from it.
  void _remember() {
    if (_nodes.isEmpty) return;
    if (_rememberedPlaces.length > _rememberedLimit) _rememberedPlaces.clear();
    for (final node in _nodes) {
      _rememberedPlaces[node.id] = Offset(node.x, node.y);
    }
    _rememberedScale = _scale;
    _rememberedOffset = _offset;
    _rememberedSize = _size;
  }

  void _step() {
    // Springs beat repulsion here on purpose. Even spacing makes a pretty
    // circle and says nothing; what the reader should see is that four things
    // hang off 맛집·카페 and one hangs off 청량리.
    const repulsion = 2300.0;
    const spring = 0.085;
    const gravity = 0.02;
    final scale = _alpha;

    for (var i = 0; i < _nodes.length; i++) {
      final a = _nodes[i];
      for (var j = i + 1; j < _nodes.length; j++) {
        final b = _nodes[j];
        var dx = a.x - b.x;
        var dy = a.y - b.y;
        var distanceSquared = dx * dx + dy * dy;
        if (distanceSquared < 0.01) {
          dx = (i - j).toDouble() * 0.1 + 0.1;
          dy = 0.1;
          distanceSquared = dx * dx + dy * dy;
        }
        final distance = math.sqrt(distanceSquared);
        final push = repulsion / distanceSquared * scale;
        a.vx += dx / distance * push;
        a.vy += dy / distance * push;
        b.vx -= dx / distance * push;
        b.vy -= dy / distance * push;
      }
    }

    for (final edge in _edges) {
      final rest = edge.a.radius + edge.b.radius + 46;
      final dx = edge.b.x - edge.a.x;
      final dy = edge.b.y - edge.a.y;
      final distance = math.max(math.sqrt(dx * dx + dy * dy), 0.01);
      final pull = (distance - rest) * spring * scale;
      edge.a.vx += dx / distance * pull;
      edge.a.vy += dy / distance * pull;
      edge.b.vx -= dx / distance * pull;
      edge.b.vy -= dy / distance * pull;
    }

    for (final node in _nodes) {
      node.vx -= node.x * gravity * scale;
      node.vy -= node.y * gravity * scale;
      node.vx *= 0.86;
      node.vy *= 0.86;
      // Two nodes that start almost on top of each other push each other
      // apart hard enough to throw one across the sky, and one node out at
      // the edge drags a line over everything and shrinks the fit for
      // everybody. No step is allowed to be a leap.
      final speed = math.sqrt(node.vx * node.vx + node.vy * node.vy);
      if (speed > 24) {
        node.vx *= 24 / speed;
        node.vy *= 24 / speed;
      }
      node.x += node.vx;
      node.y += node.vy;
    }
  }

  /// Points the camera at [shown], either at once or by flying there.
  void _frame(Iterable<_Node> shown, {bool now = false}) {
    if (_size == Size.zero) return;
    final list = shown.toList(growable: false);
    if (list.isEmpty) return;

    // Trimmed rather than absolute bounds. One node flung to the edge would
    // otherwise shrink the whole sky to fit it, and the reader would be looking
    // at a speck surrounded by nothing because of a single outlier.
    final xs = list.map((node) => node.x).toList()..sort();
    final ys = list.map((node) => node.y).toList()..sort();
    final trim = list.length > 20 ? (list.length * 0.03).round() : 0;
    final margin = list.fold<double>(0, (m, n) => math.max(m, n.radius));
    final left = xs[trim] - margin;
    final right = xs[xs.length - 1 - trim] + margin;
    final top = ys[trim] - margin;
    final bottom = ys[ys.length - 1 - trim] + margin;
    const pad = 72.0;
    final width = math.max(right - left, 1.0);
    final height = math.max(bottom - top, 1.0);
    final scale = math
        .min((_size.width - pad) / width, (_size.height - pad) / height)
        .clamp(0.12, 2.4);
    final offset = Offset(
      _size.width / 2 - (left + right) / 2 * scale,
      _size.height / 2 - (top + bottom) / 2 * scale,
    );

    if (now) {
      _scale = scale;
      _offset = offset;
      _toScale = null;
      _toOffset = null;
      return;
    }
    _toScale = scale;
    _toOffset = offset;
  }

  /// Flies to whatever the words just lit, or back out when they are cleared.
  ///
  /// Searching does not shorten a list here, so it cannot be allowed to leave
  /// the answer somewhere off screen. The camera goes to it.
  void _flyToAnswer() {
    if (widget.terms.isEmpty) {
      _handled = false;
      _frame(_nodes);
      _wake();
      return;
    }
    final lit = _nodes
        .where((node) {
          if (node.isTag) {
            return widget.terms.any(node.label.toLowerCase().contains);
          }
          return itemAnswers(node.item!, widget.terms);
        })
        .toList(growable: false);
    if (lit.isEmpty) return;
    // Only move if the answer is not already sitting there in front of them.
    // Reframing on every tap made picking a second word throw the whole sky
    // across the screen, which is disorienting and buys nothing: the reader
    // was already looking at the thing they tapped.
    if (_alreadyVisible(lit)) return;
    _handled = true;
    _frame(lit);
    _wake();
  }

  bool _alreadyVisible(List<_Node> lit) {
    final view = Rect.fromLTWH(0, 0, _size.width, _size.height).deflate(28);
    if (view.isEmpty) return false;
    for (final node in lit) {
      final at = Offset(node.x, node.y) * _scale + _offset;
      if (!view.contains(at)) return false;
    }
    // Visible but a speck is not really visible. Anything smaller than this
    // is worth flying to even though it is technically on screen.
    return lit.every((node) => node.radius * _scale >= 4);
  }

  void _tap(Offset local) {
    if (_scale == 0) return;
    final point = (local - _offset) / _scale;
    _Node? hit;
    var best = double.infinity;
    for (final node in _nodes) {
      final distance = (Offset(node.x, node.y) - point).distance;
      // A generous target in screen terms, so a far-out sky is still tappable.
      if (distance < node.radius + 14 / _scale && distance < best) {
        best = distance;
        hit = node;
      }
    }
    if (hit == null) {
      setState(() => _peeked = null);
      return;
    }
    if (hit.isTag) {
      widget.onToggleTag(hit.label);
      return;
    }
    // First touch names the star and lights the words it hangs from. The
    // second opens it. In here the reader is looking around, not filing, so
    // finding out what something is comes before going into it.
    if (_peeked == hit.id) {
      widget.onOpenItem(hit.item!);
    } else {
      setState(() => _peeked = hit!.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size != _size) {
          _size = size;
          _frame(_nodes, now: true);
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _tap(details.localPosition),
          onScaleStart: (details) {
            _gestureScale = _scale;
            _gestureOffset = _offset;
            _gestureFocal = details.localFocalPoint;
            _toScale = null;
            _toOffset = null;
            _handled = true;
          },
          onScaleUpdate: (details) {
            setState(() {
              final scale = (_gestureScale * details.scale).clamp(0.12, 3.0);
              // Keep whatever was under the fingers under the fingers.
              final anchor = (_gestureFocal - _gestureOffset) / _gestureScale;
              _scale = scale;
              _offset = details.localFocalPoint - anchor * scale;
            });
          },
          child: CustomPaint(
            size: size,
            painter: _ConstellationPainter(
              nodes: _nodes,
              edges: _edges,
              scale: _scale,
              offset: _offset,
              terms: widget.terms,
              peeked: _peeked,
            ),
          ),
        );
      },
    );
  }
}

final class _Node {
  _Node({
    required this.id,
    required this.label,
    required this.isTag,
    required this.radius,
    required this.recency,
    this.item,
  }) : phase = id.hashCode % 628 / 100;

  final String id;
  final String label;
  final bool isTag;
  final double radius;
  final double recency;
  final SavedLibraryItem? item;

  /// So every node breathes and twinkles out of step with its neighbours.
  final double phase;

  double x = 0;
  double y = 0;
  double vx = 0;
  double vy = 0;
}

final class _Link {
  const _Link(this.a, this.b);
  final _Node a;
  final _Node b;
}

/// How much of the reader's attention a node is being given.
enum _Light {
  /// It answers everything that was asked.
  full,

  /// It does not, but something that does is filed under it. This is what
  /// keeps a search readable: `을지로 닭발` leaves one shop lit and still shows
  /// that the shop is also 맛집·카페.
  context,

  /// Out of the question entirely.
  away,
}

final class _ConstellationPainter extends CustomPainter {
  _ConstellationPainter({
    required this.nodes,
    required this.edges,
    required this.scale,
    required this.offset,
    required this.terms,
    required this.peeked,
  }) : _asked = terms.isNotEmpty || peeked != null {
    // The largest handful always keep their names, at any zoom. A map with no
    // words on it is not a map, and these are the ones that got large by being
    // used, so they are the honest labels for the regions around them.
    final hubs = nodes.where((node) => node.isTag).toList()
      ..sort((a, b) => b.radius.compareTo(a.radius));
    for (final hub in hubs.take(6)) {
      _anchors.add(hub.id);
    }
    if (!_asked) return;
    for (final node in nodes) {
      if (node.isTag) continue;
      final answers = peeked != null
          ? node.id == peeked
          : itemAnswers(node.item!, terms);
      if (!answers) continue;
      _answering.add(node.id);
      for (final tag in node.item!.tags) {
        _nearby.add(tag.value);
      }
    }
  }

  final List<_Node> nodes;
  final List<_Link> edges;
  final double scale;
  final Offset offset;
  final List<String> terms;
  final String? peeked;

  final bool _asked;

  /// Ids of the saved things that answer every term, or the one being peeked.
  final _answering = <String>{};

  /// The tags those things carry — the context around the answer.
  final _nearby = <String>{};

  /// Tag ids that keep their name however far out the reader is.
  final _anchors = <String>{};

  _Light _light(_Node node) {
    if (!_asked) return _Light.full;
    if (node.isTag) {
      if (terms.any(node.label.toLowerCase().contains)) return _Light.full;
      // A peeked star hands the reader its own words, lit brightly, because
      // recovering the word is the point of touching it.
      if (peeked != null && _nearby.contains(node.label)) return _Light.full;
      return _nearby.contains(node.label) ? _Light.context : _Light.away;
    }
    return _answering.contains(node.id) ? _Light.full : _Light.away;
  }

  double _strength(_Light light) => switch (light) {
    _Light.full => 1,
    _Light.context => 0.42,
    _Light.away => 0.1,
  };

  /// The sky neither drifts nor pulses, and this is deliberate.
  ///
  /// Two hundred stars wandering on their own phases is not floating, it is
  /// static: nothing holds still long enough to be read, and none of the
  /// movement carries anything. Drifting them together is calmer but no more
  /// meaningful. So they keep their places, and the only things that move are
  /// the ones that mean something — the layout easing in when it is new, and
  /// the camera going to what a search found. When this view moves, it is
  /// because something happened.
  Offset _at(_Node node) => Offset(node.x, node.y) * scale + offset;

  @override
  void paint(Canvas canvas, Size size) {
    final edgePaint = Paint()..style = PaintingStyle.stroke;
    for (final edge in edges) {
      // A line belongs to its capture: it is lit when the thing hanging off it
      // is one of the answers.
      final lit = _light(edge.a) == _Light.full;
      edgePaint
        ..color = AppTheme.primary.withValues(
          alpha: lit ? (_asked ? 0.5 : 0.24) : 0.04,
        )
        ..strokeWidth = lit && _asked ? 1.2 : 0.8;
      canvas.drawLine(_at(edge.a), _at(edge.b), edgePaint);
    }

    for (final node in nodes) {
      final strength = _strength(_light(node));
      if (node.isTag) {
        _paintTag(canvas, node, strength);
      } else {
        _paintItem(canvas, node, strength);
      }
    }

    _paintLabels(canvas);
  }

  /// Names as many nodes as can be read, and no more.
  ///
  /// Every label after every node, or a word drawn early vanishes behind a
  /// star drawn late. Then in order of importance, refusing any that would
  /// land on one already placed — which is the only thing that actually keeps
  /// a crowded sky legible. Zooming in spreads the nodes apart, more labels
  /// stop colliding, and more words appear. That is the whole scale story:
  /// far out you read the regions, close in you read the streets.
  void _paintLabels(Canvas canvas) {
    final placed = <Rect>[];
    final queue = <_Node>[
      // What the reader asked about comes first: a search must never be
      // answered by a word that lost its place to a bigger neighbour.
      for (final node in nodes)
        if (_asked && _light(node) == _Light.full) node,
      for (final node in nodes)
        if (node.isTag && _anchors.contains(node.id) && !_isAnswer(node)) node,
      ...(nodes
          .where(
            (node) =>
                node.isTag &&
                !_anchors.contains(node.id) &&
                !_isAnswer(node) &&
                node.radius * scale >= _namesItselfAt,
          )
          .toList()
        ..sort((a, b) => b.radius.compareTo(a.radius))),
    ];

    for (final node in queue) {
      final light = _light(node);
      if (!node.isTag && !(_asked && light == _Light.full)) continue;
      _paintLabel(
        canvas,
        node.label,
        _at(node) + Offset(0, node.radius * scale + 7),
        _strength(light),
        answer: !node.isTag,
        placed: placed,
      );
    }
  }

  bool _isAnswer(_Node node) => _asked && _light(node) == _Light.full;

  void _paintTag(Canvas canvas, _Node node, double strength) {
    final centre = _at(node);
    final radius = node.radius * scale;
    // Only the hubs glow. Fifty small words each carrying a halo add up to a
    // green wash with no structure in it — the bloom has to be rationed to the
    // few nodes it is actually saying something about.
    if (radius >= 7) {
      canvas.drawCircle(
        centre,
        radius * 2.1,
        Paint()
          ..color = AppTheme.primary.withValues(alpha: 0.07 * strength)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
    }
    canvas.drawCircle(
      centre,
      radius,
      Paint()..color = AppTheme.primary.withValues(alpha: 0.95 * strength),
    );
  }

  void _paintItem(Canvas canvas, _Node node, double strength) {
    final centre = _at(node);
    final radius = node.radius * scale;
    // Recency reads as light rather than position: a thing saved this morning
    // sits wherever its tags put it and simply burns brighter.
    final glow = 0.3 + 0.7 * node.recency;

    canvas.drawCircle(
      centre,
      radius * 2.6,
      Paint()
        ..color = AppTheme.ink.withValues(alpha: 0.13 * glow * strength)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );

    // Nothing filed anywhere hangs off nothing, and says so. The reader does
    // not need the words 태그 없음 to see which stars are adrift.
    final adrift = node.item!.tags.isEmpty;
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..color = (adrift ? AppTheme.caution : AppTheme.ink).withValues(
          alpha: (adrift ? 0.5 : 0.35 + 0.65 * node.recency) * strength,
        ),
    );
    if (adrift) {
      canvas.drawCircle(
        centre,
        radius + 3.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = AppTheme.caution.withValues(alpha: 0.55 * strength),
      );
    }
  }

  /// A label with the background painted back in behind it, so a word stays
  /// readable wherever the layout happens to drop it.
  void _paintLabel(
    Canvas canvas,
    String text,
    Offset top,
    double strength, {
    required List<Rect> placed,
    bool answer = false,
  }) {
    final style = TextStyle(
      fontSize: answer ? 13 : 12,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.1,
    );
    final halo = TextPainter(
      text: TextSpan(
        text: text,
        style: style.copyWith(
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.4
            ..strokeJoin = StrokeJoin.round
            ..color = AppTheme.background.withValues(alpha: 0.92 * strength),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final face = TextPainter(
      text: TextSpan(
        text: text,
        style: style.copyWith(
          color: (answer ? AppTheme.primary : AppTheme.ink).withValues(
            alpha: strength,
          ),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final at = top - Offset(face.width / 2, 0);
    final box = Rect.fromLTWH(at.dx, at.dy, face.width, face.height).inflate(3);
    for (final taken in placed) {
      if (box.overlaps(taken)) return;
    }
    placed.add(box);
    halo.paint(canvas, at);
    face.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_ConstellationPainter old) => true;
}
