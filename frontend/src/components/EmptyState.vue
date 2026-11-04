<script setup lang="ts">
import { t } from "../lib/i18n";
withDefaults(
  defineProps<{ title?: string; description?: string; compact?: boolean }>(),
  {
    title: "让第一个瞬间，成为故事的开始",
    description: "那些平凡又闪光的小日子，都值得被好好收藏。",
  },
);
</script>
<template>
  <div class="empty-state" :class="{ compact }">
    <div class="memory-art">
      <svg viewBox="0 0 300 190" aria-hidden="true">
        <circle cx="150" cy="98" r="79" fill="var(--sage-light)" />
        <path
          d="M34 145Q80 120 130 143T272 140"
          fill="none"
          stroke="#d7d7c6"
          stroke-width="1"
        />
        <g transform="rotate(-13 130 90)">
          <rect
            x="57"
            y="31"
            width="105"
            height="131"
            rx="6"
            fill="#eee4d7"
            stroke="#dbd1c0"
          />
          <rect x="65" y="40" width="89" height="91" rx="2" fill="#c8c9ad" />
          <circle cx="121" cy="65" r="15" fill="#f6e4a4" />
          <path
            d="M65 112L92 81L118 106L136 86L154 115V131H65Z"
            fill="#909f82"
          />
          <path
            d="M81 143h39"
            stroke="#bcb29f"
            stroke-width="3"
            stroke-linecap="round"
          />
        </g>
        <g transform="rotate(11 185 106)">
          <rect
            x="131"
            y="54"
            width="105"
            height="131"
            rx="6"
            fill="#fffdf8"
            stroke="#ded9ce"
          />
          <rect x="139" y="63" width="89" height="91" rx="2" fill="#e7d9bb" />
          <circle cx="181" cy="91" r="16" fill="#eab586" />
          <path d="M152 154q1-48 29-48t30 48" fill="#a9b69b" />
          <path
            d="M164 167h39"
            stroke="#d1c8b9"
            stroke-width="3"
            stroke-linecap="round"
          />
        </g>
        <path d="M251 61l4 8 9 1-7 6 2 9-8-5-8 5 2-9-7-6 9-1z" fill="#d0a868" />
        <path
          d="M45 59q-6-21-16-17q-6 11 16 17m0 0q5-24 14-20q6 12-14 20"
          fill="#a9b898"
        />
      </svg>
    </div>
    <h3>{{ t(title) }}</h3>
    <p>{{ t(description) }}</p>
    <slot />
  </div>
</template>
