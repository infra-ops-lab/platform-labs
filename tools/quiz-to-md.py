#!/usr/bin/env python3
"""Generate quiz/README.md from quiz/questions.json (the single source of the questions).

Options are shuffled with a fixed seed per question, so the correct answer isn't always
in the same position, and the output only changes when the questions change.
Run: python3 tools/quiz-to-md.py
"""
import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LETTERS = "abcd"
NAMES = {
    0: "Fleet tour", 1: "Fleet GitOps", 2: "Golden path", 3: "Run the golden path",
    4: "Progressive delivery", 5: "Guardrails", 6: "Canary releases", 7: "Fleet CLI in Go",
    8: "Design RFC", 9: "Self-service database", 10: "Supply chain", 11: "Cost per tenant",
    12: "Kafka topics as code", 99: "Mixed scenarios",
}


def shuffled(q, seed):
    order = list(range(len(q["options"])))
    random.Random(seed).shuffle(order)
    return [q["options"][i] for i in order], order.index(q["answer"])


def main():
    questions = json.loads((ROOT / "quiz" / "questions.json").read_text())
    out = [
        "# Quiz: test yourself",
        "",
        "%d multiple-choice questions on every lab. Pick an answer, then open **Show answer**." % len(questions),
        "",
        "**Interactive version** (random order, filter by lab, score): [play the quiz](play.html)",
        "(on the website; on GitHub the link shows the page source).",
        "",
        "This page is generated from `quiz/questions.json` by `tools/quiz-to-md.py`. Edit the JSON, not this file.",
        "",
    ]
    n = 0
    for lab in sorted({q["lab"] for q in questions}):
        title = NAMES.get(lab, "Lab %d" % lab)
        out += ["## %s" % (title if lab == 99 else "Lab %d: %s" % (lab, title)), ""]
        for q in [q for q in questions if q["lab"] == lab]:
            n += 1
            options, correct = shuffled(q, n)
            out.append("**%d.** %s" % (n, q["q"]))
            out.append("")
            for letter, opt in zip(LETTERS, options):
                out.append("- **%s)** %s" % (letter, opt))
            out += [
                "",
                '<details markdown="1"><summary>Show answer</summary>',
                "",
                "**%s)** %s" % (LETTERS[correct], options[correct]),
                "",
                q["why"],
                "",
                "</details>",
                "",
            ]
    (ROOT / "quiz" / "README.md").write_text("\n".join(out))
    print("wrote quiz/README.md with %d questions" % n)


if __name__ == "__main__":
    main()
