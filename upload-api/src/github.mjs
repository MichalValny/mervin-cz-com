function workflowDispatchError(status, text, repo, workflow) {
  if (status === 403) {
    return new Error(
      `GitHub workflow dispatch failed (${status}): token nemá oprávnění. UPLOAD_GITHUB_TOKEN musí mít scope repo + workflow (classic PAT) nebo Actions: Read and write (fine-grained PAT). ${text}`
    );
  }
  if (status === 404) {
    return new Error(
      `GitHub workflow dispatch failed (${status}): workflow ${workflow} nenalezen v ${repo}. ${text}`
    );
  }
  return new Error(`GitHub workflow dispatch failed (${status}): ${text}`);
}

export async function triggerUploadWorkflow({ token, repo, workflow, uploadId, author }) {
  const [owner, name] = repo.split('/');
  const response = await fetch(`https://api.github.com/repos/${owner}/${name}/actions/workflows/${encodeURIComponent(workflow)}/dispatches`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      ref: 'main',
      inputs: {
        upload_id: uploadId,
        author,
      },
    }),
  });

  if (!response.ok) {
    const text = await response.text();
    throw workflowDispatchError(response.status, text, repo, workflow);
  }
}
