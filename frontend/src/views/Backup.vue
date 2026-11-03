<script setup lang="ts">
import { ref } from "vue";
import {
  Download,
  ShieldCheck,
  FolderArchive,
  ArrowUpRight,
  FileJson,
  FileSpreadsheet,
  HardDrive,
  Check,
} from "lucide-vue-next";
import { useYearly } from "../stores/yearly";
import { bytes } from "../lib/api";
const yearly = useYearly();
</script>
<template>
  <div class="page-heading">
    <div>
      <span class="eyebrow">MEMORIES THAT BELONG TO YOU</span>
      <h1>让回忆，走得更远。</h1>
      <p>用独立格式带走你的家庭档案，给珍贵的时光多一份保障。</p>
    </div>
  </div>
  <div v-if="!yearly.isAdmin" class="notice">
    备份与导出由家庭管理员管理。请联系管理员获取家庭数据。
  </div>
  <template v-else
    ><div class="backup-banner">
      <div class="backup-symbol">
        <FolderArchive :size="42" stroke-width="1.4" />
      </div>
      <div>
        <h2>数据、关系、原件，一起保存。</h2>
        <p>
          当前已珍藏 {{ yearly.stats.media }} 份影像，{{
            yearly.stats.events
          }}
          篇成长日记，原文件共 {{ bytes(yearly.stats.bytes) }}。
        </p>
        <span
          ><ShieldCheck :size="14" />稳定媒体 ID · 关系完整保留 · SHA-256
          文件清单</span
        >
      </div>
    </div>
    <div class="export-grid">
      <a href="/api/export/manifest" class="panel export-card"
        ><FileJson :size="29" />
        <h2>完整档案清单</h2>
        <p>孩子资料、逻辑媒体、原始元数据、成长日记及全部关联关系。</p>
        <span>下载 JSON<Download :size="16" /></span></a
      ><a href="/api/export/files.csv" class="panel export-card"
        ><FileSpreadsheet :size="29" />
        <h2>原文件索引</h2>
        <p>物理文件大小、OSS 对象路径、SHA-256 与 CRC64，适合核对和迁移。</p>
        <span>下载 CSV<Download :size="16" /></span
      ></a>
    </div>
    <section class="panel backup-guide">
      <span class="eyebrow">A RECOVERABLE COPY, EVERY TIME</span>
      <h2>完整备份与恢复</h2>
      <p class="muted">
        JSON / CSV 清单包含敏感家庭信息，请妥善保存。下载清单后，还需要备份 OSS
        原件与数据库。
      </p>
      <ol class="backup-steps">
        <li>
          <span>01</span>
          <div>
            <h3>备份数据库</h3>
            <p>
              在服务器运行部署目录的
              <code>backup-mysql.sh</code
              >，使用一致性事务备份全部数据。数据库密码从本机权限为 600
              的客户端配置读取。
            </p>
          </div>
        </li>
        <li>
          <span>02</span>
          <div>
            <h3>下载并校验原文件</h3>
            <p>
              运行管理命令，原件逐份从 OSS 下载到独立存储，分块计算
              SHA-256。已备份且校验通过的文件会自动跳过。
            </p>
            <pre>python -m app.cli backup /secure-backups/yearly</pre>
          </div>
        </li>
        <li>
          <span>03</span>
          <div>
            <h3>在新环境恢复完整关系</h3>
            <p>
              先建立新数据库、执行迁移并创建管理员，再将文件恢复到目标私有
              Bucket。清单保留原媒体 ID，恢复孩子和事件关联。
            </p>
            <pre>
python -m app.cli restore /secure-backups/yearly/manifest.json \
  --owner-id 1 --objects /secure-backups/yearly/objects
python -m app.cli verify-oss</pre>
          </div>
        </li>
        <li>
          <span>04</span>
          <div>
            <h3>验证恢复结果</h3>
            <p>
              核对孩子、照片与共同日记数量，随机下载原件校验
              SHA-256，确认两个孩子的共同影像均可浏览。
            </p>
          </div>
        </li>
      </ol>
      <div class="notice subtle">
        <HardDrive :size="20" />
        <p>
          建议保留一份异地离线备份，并开启 OSS 版本控制。完整步骤与 MySQL
          恢复命令见仓库中的备份恢复文档。
        </p>
      </div>
    </section></template
  >
</template>
