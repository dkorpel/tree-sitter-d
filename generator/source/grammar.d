import std.algorithm.comparison;
import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.exception;
import std.format;
import std.sumtype;

import ae.utils.aa;
import ae.utils.meta;

import ddoc;

struct Grammar
{
	struct RegExp { string regexp; }
	struct LiteralChars { string chars; } // Describes contiguous characters (e.g. number syntax)
	struct LiteralToken { string literal; } // May be surrounded by whitespace/comments
	struct Reference { string name; }
	struct Choice { Node[] nodes; }
	struct Seq { Node[] nodes; }
	struct Repeat { Node[/*1*/] node; } // https://issues.dlang.org/show_bug.cgi?id=22010
	struct Repeat1 { Node[/*1*/] node; } // https://issues.dlang.org/show_bug.cgi?id=22010
	struct Optional { Node[/*1*/] node; } // https://issues.dlang.org/show_bug.cgi?id=22010
	// https://issues.dlang.org/show_bug.cgi?id=22003
	alias NodeValue = SumType!(
		RegExp,
		LiteralChars,
		LiteralToken,
		Reference,
		Choice,
		Repeat,
		Repeat1,
		Seq,
		Optional,
	);
	struct Node
	{
		NodeValue value;
		alias value this;
	}
	struct Def
	{
		Node node;

		enum Kind
		{
			tokens,
			chars,
		}
		Kind kind;

		bool used;
		bool hidden;
	}

	Def[string] defs;

	/// Pre-process and prepare for writing
	void analyze(string[] roots)
	{
		checkReferences();
		optimize();
		checkKinds();
		scanUsed(roots);
		scanHidden();
	}

	// Ensure that all referenced grammar definitions are defined.
	private void checkReferences()
	{
		void scan(Node node)
		{
			node.value.match!(
				(ref RegExp       v) {},
				(ref LiteralChars v) {},
				(ref LiteralToken v) {},
				(ref Reference    v) { enforce(v.name in defs, "Unknown reference: " ~ v.name); },
				(ref Choice       v) { v.nodes.each!scan(); },
				(ref Seq          v) { v.nodes.each!scan(); },
				(ref Repeat       v) { v.node .each!scan(); },
				(ref Repeat1      v) { v.node .each!scan(); },
				(ref Optional     v) { v.node .each!scan(); },
			);
		}
		foreach (name, ref def; defs)
			scan(def.node);
	}

	// Fold away unnecessary grammar nodes, or refactor into simpler constructs which
	// are available in tree-sitter but not used in the D grammar specification.
	private void optimize()
	{
		void optimizeNode(ref Node node)
		{
			// Optimize children
			node.value.match!(
				(ref RegExp       v) {},
				(ref LiteralChars v) {},
				(ref LiteralToken v) {},
				(ref Reference    v) {},
				(ref Choice       v) { v.nodes.each!optimizeNode(); },
				(ref Seq          v) { v.nodes.each!optimizeNode(); },
				(ref Repeat       v) { v.node .each!optimizeNode(); },
				(ref Repeat1      v) { v.node .each!optimizeNode(); },
				(ref Optional     v) { v.node .each!optimizeNode(); },
			);

			// Optimize node
			node = node.value.match!(
				(ref RegExp       v) => node,
				(ref LiteralChars v) => node,
				(ref LiteralToken v) => node,
				(ref Reference    v) => node,
				(ref Choice       v) => v.nodes.length == 1 ? v.nodes[0] : node,
				(ref Seq          v) => v.nodes.length == 1 ? v.nodes[0] : node,
				(ref Repeat       v) => node,
				(ref Repeat1      v) => node,
				(ref Optional     v) => node,
			);

			// Transform choice(a, seq(a, b)) into seq(a, optional(b))
			node.value.match!(
				(ref Choice choice)
				{
					if (choice.nodes.length < 2)
						return;
					auto prefix = choice.nodes[0].match!(
						(ref Seq seq) => seq.nodes,
						(_) => choice.nodes[0 .. 1],
					);
					if (!prefix)
						return;

					bool samePrefix = choice.nodes[1 .. $].map!((ref n) => n.match!(
						(ref Seq seq) => seq.nodes.startsWith(prefix),
						(_) => false,
					)).all;
					if (!samePrefix)
						return;

					node = Node(NodeValue(Seq(
						prefix ~
						Node(NodeValue(Optional([
							Node(NodeValue(Choice(
								choice.nodes[1 .. $].map!((ref n) => Node(NodeValue(Seq(
									n.tryMatch!(
										(ref Seq seq) => seq.nodes[prefix.length .. $],
									)
								))))
								.array,
							)))
						])))
					)));
					optimizeNode(node);
				},
				(ref _) {},
			);
		}

		foreach (name, ref def; defs)
		{
			optimizeNode(def.node);

			// Transform x := seq(y, optional(x)) into x := repeat1(y)
			// (attempt to remove recursion)
			{
				def.node.match!(
					(ref Seq seq)
					{
						if (seq.nodes.length != 2)
							return;
						seq.nodes[1].match!(
							(ref Optional optional)
							{
								optional.node[0].match!(
									(ref Reference reference)
									{
										if (reference.name != name)
											return;

										def.node = Node(NodeValue(Repeat1([
											seq.nodes[0],
										])));
									},
									(_) {}
								);
							},
							(_) {}
						);
					},
					(_) {}
				);
			}

			// Transform x := seq(y, optional(seq(z, x))) into x := seq(y, repeat(seq(z, y)))
			// (attempt to remove recursion)
			{
				def.node.match!(
					(ref Seq seq1)
					{
						if (seq1.nodes.length < 2)
							return;
						seq1.nodes[$-1].match!(
							(ref Optional optional)
							{
								optional.node[0].match!(
									(ref Seq seq2)
									{
										if (seq2.nodes.length < 2)
											return;
										seq2.nodes[$-1].match!(
											(ref Reference reference)
											{
												if (reference.name != name)
													return;

												def.node = Node(NodeValue(Seq(
													seq1.nodes[0 .. $-1] ~
													Node(NodeValue(Repeat([
														Node(NodeValue(Seq(
															seq2.nodes[0 .. $-1] ~
															seq1.nodes[0 .. $-1],
														))),
													]))),
												)));
											},
											(_) {}
										);
									},
									(_) {}
								);
							},
							(_) {}
						);
					},
					(_) {}
				);
			}

			// Transform x := seq(y, optional(seq(z, optional(x)))) into x := seq(y, repeat(seq(z, y)), optional(z))
			// (attempt to remove recursion)
			{
				def.node.match!(
					(ref Seq seq1)
					{
						if (seq1.nodes.length < 2)
							return;
						auto y = seq1.nodes[0 .. $-1];
						seq1.nodes[$-1].match!(
							(ref Optional optional1)
							{
								optional1.node[0].match!(
									(ref Seq seq2)
									{
										if (seq2.nodes.length < 2)
											return;
										auto z = seq2.nodes[0 .. $-1];
										seq2.nodes[$-1].match!(
											(ref Optional optional1)
											{
												optional1.node[0].match!(
													(ref Reference reference)
													{
														if (reference.name != name)
															return;
														auto x = reference;

														def.node = Node(NodeValue(Seq(
															y ~
															Node(NodeValue(Repeat([
																Node(NodeValue(Seq(
																	z ~
																	y
																)))
															]))) ~
															Node(NodeValue(Optional([
																Node(NodeValue(Seq(
																	z
																)))
															])))
														)));
														optimizeNode(def.node);
													},
													(_) {}
												);
											},
											(_) {}
										);
									},
									(_) {}
								);
							},
							(_) {}
						);
					},
					(_) {}
				);
			}
		}
	}

	// Verify our assertions about definitions of the respective kind.
	private void checkKinds()
	{
		foreach (defName, ref def; defs)
			final switch (def.kind)
			{
				case Def.Kind.chars:
				{
					enum State : ubyte
					{
						hasChars = 1 << 0,
						hasToken = 1 << 1,
						recurses = 1 << 2,
					}

					HashSet!string scanning;

					State checkDef(string defName)
					{
						scope(failure) { import std.stdio; stderr.writefln("While checking %s:", defName); }
						if (defName in scanning)
							return State.recurses;
						scanning.add(defName);
						scope(success) scanning.remove(defName);

						State concat(State a, State b)
						{
							if (((a & State.hasToken) && b != 0) ||
								((b & State.hasToken) && a != 0))
								throw new Exception("Token / token fragment definition %s contains mixed %s and %s".format(defName, a, b));
							return a | b;
						}

						State scanNode(ref Node node)
						{
							return node.value.match!(
								(ref RegExp       v) => State.init,
								(ref LiteralChars v) => State.hasChars,
								(ref LiteralToken v) => State.hasToken,
								(ref Reference    v) { enforce(defs[v.name].kind == Def.Kind.chars, "%s of kind %s references %s of kind %s".format(defName, def.kind, v.name, defs[v.name].kind)); return checkDef(v.name); },
								(ref Choice       v) => v.nodes.map!scanNode().fold!((a, b) => State(a | b)),
								(ref Seq          v) => v.nodes.map!scanNode().fold!concat,
								(ref Repeat       v) => v.node[0].I!scanNode().I!(x => concat(x, x)),
								(ref Repeat1      v) => v.node[0].I!scanNode().I!(x => concat(x, x)),
								(ref Optional     v) => v.node[0].I!scanNode(),
							);
						}
						return scanNode(defs[defName].node);
					}

					checkDef(defName);
					break;
				}

				case Def.Kind.tokens:
				{
					void scanNode(ref Node node)
					{
						node.value.match!(
							(ref RegExp       v) {},
							(ref LiteralChars v) { throw new Exception("Definition %s with kind %s has literal chars: %(%s%)".format(defName, def.kind, [v.chars])); },
							(ref LiteralToken v) {},
							(ref Reference    v) {},
							(ref Choice       v) { v.nodes.each!scanNode(); },
							(ref Seq          v) { v.nodes.each!scanNode(); },
							(ref Repeat       v) { v.node .each!scanNode(); },
							(ref Repeat1      v) { v.node .each!scanNode(); },
							(ref Optional     v) { v.node .each!scanNode(); },
						);
					}
					scanNode(def.node);
					break;
				}
			}
	}

	// Recursively visit definitions starting from `roots` to find
	// which ones are used and should be generated grammar.
	private void scanUsed(string[] roots)
	{
		void scanDef(string defName)
		{
			auto def = &defs[defName];
			if (def.used)
				return;
			def.used = true;
			if (def.kind == Def.Kind.chars)
				return; // Referencees will be inlined

			void scanNode(ref Node node)
			{
				node.value.match!(
					(ref RegExp       v) {},
					(ref LiteralChars v) {},
					(ref LiteralToken v) {},
					(ref Reference    v) { scanDef(v.name); },
					(ref Choice       v) { v.nodes.each!scanNode(); },
					(ref Seq          v) { v.nodes.each!scanNode(); },
					(ref Repeat       v) { v.node .each!scanNode(); },
					(ref Repeat1      v) { v.node .each!scanNode(); },
					(ref Optional     v) { v.node .each!scanNode(); },
				);
			}
			scanNode(def.node);
		}

		foreach (root; roots)
			scanDef(root);
	}

	// Choose which definitions should be hidden (inlined) in the tree-sitter AST.
	// In the generated grammar, such definitions' names begin with an underscore.
	private void scanHidden()
	{
		foreach (defName, ref def; defs)
		{
			if (def.kind == Def.Kind.chars)
				continue; // Always represents a token; referencees are inlined

			// We make a definition hidden if it always contains at most one other definition.
			// Definitions which directly contain tokens are never hidden.

			size_t scanNode(ref Node node)
			{
				return node.value.match!(
					(ref RegExp       v) => enforce(0),
					(ref LiteralChars v) => enforce(0),
					(ref LiteralToken v) => 2,
					(ref Reference    v) => 1,
					(ref Choice       v) => v.nodes.map!scanNode().reduce!max(),
					(ref Seq          v) => v.nodes.map!scanNode().sum(),
					(ref Repeat       v) => v.node[0].I!scanNode() * 2,
					(ref Repeat1      v) => v.node[0].I!scanNode() * 2,
					(ref Optional     v) => v.node[0].I!scanNode(),
				);
			}
			def.hidden = scanNode(def.node) <= 1;
		}
	}
}

/// Convenience factory functions.
Grammar.Node regexp      (string         regexp ) { return Grammar.Node(Grammar.NodeValue(Grammar.RegExp      ( regexp  ))); }
Grammar.Node literalChars(string         chars  ) { return Grammar.Node(Grammar.NodeValue(Grammar.LiteralChars( chars   ))); } /// ditto
Grammar.Node literalToken(string         literal) { return Grammar.Node(Grammar.NodeValue(Grammar.LiteralToken( literal ))); } /// ditto
Grammar.Node reference   (string         name   ) { return Grammar.Node(Grammar.NodeValue(Grammar.Reference   ( name    ))); } /// ditto
Grammar.Node choice      (Grammar.Node[] nodes  ) { return Grammar.Node(Grammar.NodeValue(Grammar.Choice      ( nodes   ))); } /// ditto
Grammar.Node seq         (Grammar.Node[] nodes  ) { return Grammar.Node(Grammar.NodeValue(Grammar.Seq         ( nodes   ))); } /// ditto
Grammar.Node repeat      (Grammar.Node   node   ) { return Grammar.Node(Grammar.NodeValue(Grammar.Repeat      ([node   ]))); } /// ditto
Grammar.Node repeat1     (Grammar.Node   node   ) { return Grammar.Node(Grammar.NodeValue(Grammar.Repeat1     ([node   ]))); } /// ditto
Grammar.Node optional    (Grammar.Node   node   ) { return Grammar.Node(Grammar.NodeValue(Grammar.Optional    ([node   ]))); } /// ditto
