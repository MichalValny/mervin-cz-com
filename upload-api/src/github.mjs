function dispatchError(status, text, repo, method) {
  if (status === 403) {
    return new Error(
      `GitHub ${method} failed (${status}): token nemá oprávnění. UPLOAD_GITHUB_TOKEN musí mít scope repo (classic PAT) nebo Contents: Read and write (fine-grained PAT). ${text}`
    );
  }
  return new Error(`GitHub ${method} failed (${status}): ${text}`);
}

export async function triggerUploadWorkflow({ token, repo, uploadId, author }) {
  const [owner, name] = repo.split('/');
  const headers = {
    Authorization: `Bearer ${token}`,
    Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'Content-Type': 'application/json',
  };

  const response = await fetch(`https://api.github.com/repos/${owner}/${name}/dispatches`, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      event_type: 'process-upload',
      client_payload: {
        upload_id: uploadId,
        author,
      },
    }),
  });

  if (!response.ok) {
    const text = await response.text();
    throw dispatchError(response.status, text, repo, 'repository_dispatch');
  }
}
