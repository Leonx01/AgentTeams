import unittest
from unittest.mock import AsyncMock, patch

from gateway.platforms._matrix_native import MatrixAdapter as NativeMatrixAdapter
from hermes_matrix.overlay_adapter import MatrixAdapter, MembershipEventDispatcher


class FakeClient:
    def __init__(self):
        self.dispatchers = []
        self.sync = AsyncMock(return_value={
            "rooms": {"invite": {"!project:example.test": {}}},
        })

    def add_dispatcher(self, dispatcher):
        self.dispatchers.append(dispatcher)

    async def send_message_event(self, *_args, **_kwargs):
        return None


class MatrixAdapterConnectTests(unittest.IsolatedAsyncioTestCase):
    async def test_connect_enables_and_drains_room_invites(self):
        client = FakeClient()
        adapter = object.__new__(MatrixAdapter)
        adapter._client = None
        adapter._user_id = "@alice:example.test"
        adapter._on_invite = AsyncMock()

        async def native_connect(instance):
            instance._client = client
            return True

        with patch.object(NativeMatrixAdapter, "connect", native_connect):
            self.assertTrue(await adapter.connect())

        self.assertIn(MembershipEventDispatcher, client.dispatchers)
        client.sync.assert_awaited_once_with(timeout=0, full_state=True)
        adapter._on_invite.assert_awaited_once()
        self.assertEqual(
            adapter._on_invite.await_args.args[0].room_id,
            "!project:example.test",
        )


if __name__ == "__main__":
    unittest.main()
