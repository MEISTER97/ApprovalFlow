import os
import re
from typing import List


class PolicyRetriever:
    def __init__(self, policy_path: str = "policy.md"):
        self.chunks: List[dict] = []
        self._index_policy(policy_path)

    def _index_policy(self, policy_path: str):
        """Reads policy.md and splits it into structured, indexed Markdown chunks."""
        if not os.path.exists(policy_path):
            print(f"[PolicyRetriever] Warning: {policy_path} not found.")
            return

        with open(policy_path, "r", encoding="utf-8") as f:
            raw_text = f.read()

        # Split document by Markdown Level 1 or Level 2 headings (# or ##)
        raw_sections = re.split(r'\n(?=#+\s)', raw_text)

        for idx, section in enumerate(raw_sections):
            section = section.strip()
            if not section:
                continue

            # Extract header title
            header_match = re.match(r'^#+\s*(.+)', section)
            title = header_match.group(1).lower() if header_match else f"clause_{idx}"

            self.chunks.append({
                "id": idx,
                "title": title,
                "text": section
            })
        print(f"[PolicyRetriever] Successfully indexed {len(self.chunks)} policy clauses.")

    def retrieve(self, category: str, query_text: str = "") -> str:
        """
        Retrieves relevant policy clauses:
        Always includes 'global' rules + clauses matching the specific invoice category or keywords.
        """
        if not self.chunks:
            return "Standard Corporate Expense Policy Applies."

        category = (category or "").lower()
        query_text = (query_text or "").lower()

        relevant_chunks = []

        for chunk in self.chunks:
            title = chunk["title"]
            text_lower = chunk["text"].lower()

            # 1. Always include Global / General / Core Policy definitions
            if any(k in title for k in ["global", "general", "overview", "purpose", "scope", "authority"]):
                relevant_chunks.append(chunk["text"])
                continue

            # 2. Match Exact Category (e.g., 'meals', 'travel', 'saas', 'hardware')
            if category and (category in title or category in text_lower):
                relevant_chunks.append(chunk["text"])
                continue

            # 3. Keyword matching on invoice description/notes
            keywords = ["flight", "hotel", "taxi", "uber", "software", "subscription", "server", "laptop", "lunch",
                        "dinner", "client"]
            for kw in keywords:
                if kw in query_text and kw in text_lower:
                    relevant_chunks.append(chunk["text"])
                    break

        # Remove duplicates while preserving order
        unique_chunks = list(dict.fromkeys(relevant_chunks))

        # Fallback: if no specific chunk matched, return the whole policy to be safe
        if not unique_chunks:
            return "\n\n---\n\n".join([c["text"] for c in self.chunks])

        return "\n\n---\n\n".join(unique_chunks)


# Global singleton instance
policy_retriever = PolicyRetriever()