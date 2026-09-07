export async function triggerUploadWorkflow({ token, repo, workflow, uploadId, author }) {
  const [owner, name] = repo.split('/');
  const response = await fetch(`https://api.github.com/repos/${owner}/${name}/actions/workflows/${workflow}/dispatches`, {
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
    throw new Error(`GitHub workflow dispatch failed (${response.status}): ${text}`);
  }
}
