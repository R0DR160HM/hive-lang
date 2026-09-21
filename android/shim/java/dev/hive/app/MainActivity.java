package dev.hive.app;

import android.app.Activity;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.os.Bundle;
import android.util.Log;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.net.InetAddress;
import java.util.List;
import java.util.Map;

// The whole of a Hive app on Android. The program in lib/arm64-v8a is an
// ordinary Hive executable that already serves its own window over loopback;
// this only starts it, learns the port, and points a WebView at it.
public class MainActivity extends Activity {

	private static final String TAG = "hive";

	// The payload is named lib*.so so the installer extracts it into
	// nativeLibraryDir, which is the one directory in an app that is executable.
	private static final String PAYLOAD = "libhiveapp.so";

	// What the runtime prints where it has no browser to launch.
	private static final String WINDOW = "hive-window ";

	private WebView view;
	private Process child;

	@Override
	protected void onCreate(Bundle state) {
		super.onCreate(state);

		view = new WebView(this);
		WebSettings settings = view.getSettings();
		settings.setJavaScriptEnabled(true);
		settings.setDomStorageEnabled(true);
		// A scene's sounds are part of the program, not something the user asked
		// for a gesture at a time.
		settings.setMediaPlaybackRequiresUserGesture(false);
		view.setWebViewClient(new WebViewClient());

		// API 35 lays an app out edge to edge whether it asked to be. The padding goes
		// on the frame, not the WebView: padding a WebView insets what it draws without
		// changing the size it reports, so 100dvh would still cover the navigation bar.
		FrameLayout frame = new FrameLayout(this);
		frame.addView(view, new FrameLayout.LayoutParams(
			ViewGroup.LayoutParams.MATCH_PARENT,
			ViewGroup.LayoutParams.MATCH_PARENT));
		frame.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
			public WindowInsets onApplyWindowInsets(View v, WindowInsets insets) {
				v.setPadding(
					insets.getSystemWindowInsetLeft(),
					insets.getSystemWindowInsetTop(),
					insets.getSystemWindowInsetRight(),
					insets.getSystemWindowInsetBottom());
				return insets;
			}
		});

		setContentView(frame);

		// Before the program starts, so its first lookup has somewhere to go.
		writeResolvers();
		watchNetwork();

		Thread runner = new Thread(new Runnable() {
			public void run() {
				serve();
			}
		});
		runner.setDaemon(true);
		runner.start();
	}

	// Starts the program and reads its output until it says where it is
	// listening. Everything it prints goes to logcat either way, which is where
	// a handset's stdout belongs.
	private void serve() {
		try {
			File home = getFilesDir();
			String exe = getApplicationInfo().nativeLibraryDir + "/" + PAYLOAD;

			ProcessBuilder built = new ProcessBuilder(exe);
			built.directory(home);
			built.redirectErrorStream(true);

			Map<String, String> environment = built.environment();
			// hive.env reads .env against the working directory; syslink's cluster
			// key and the resolvers written below both live under $HOME.
			environment.put("HOME", home.getAbsolutePath());
			environment.put("TMPDIR", getCacheDir().getAbsolutePath());

			child = built.start();

			BufferedReader out = new BufferedReader(
				new InputStreamReader(child.getInputStream()));
			String line;
			boolean opened = false;
			while ((line = out.readLine()) != null) {
				Log.i(TAG, line);
				if (!opened && line.startsWith(WINDOW)) {
					opened = true;
					show(line.substring(WINDOW.length()).trim());
				}
			}
			Log.i(TAG, "hive: the program ended");
		} catch (Exception why) {
			Log.e(TAG, "hive: " + why);
		}
	}

	private void show(final String url) {
		runOnUiThread(new Runnable() {
			public void run() {
				view.loadUrl(url);
			}
		});
	}

	// Go's resolver has no /etc/resolv.conf to read here, so the addresses this
	// network is using are written where it does look: $HOME/.hive/resolvers,
	// one a line. The runtime reads it again whenever it has been written.
	private void writeResolvers() {
		try {
			ConnectivityManager manager =
				(ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
			if (manager == null) {
				return;
			}
			Network active = manager.getActiveNetwork();
			LinkProperties properties =
				active == null ? null : manager.getLinkProperties(active);

			StringBuilder said = new StringBuilder();
			if (properties != null) {
				List<InetAddress> servers = properties.getDnsServers();
				for (InetAddress server : servers) {
					said.append(server.getHostAddress()).append("\n");
				}
			}

			File file = new File(new File(getFilesDir(), ".hive"), "resolvers");
			File parent = file.getParentFile();
			if (parent != null) {
				parent.mkdirs();
			}
			FileOutputStream to = new FileOutputStream(file);
			try {
				to.write(said.toString().getBytes("UTF-8"));
			} finally {
				to.close();
			}
		} catch (Exception why) {
			Log.w(TAG, "hive: could not write the resolvers — " + why);
		}
	}

	// A handset moves between networks and the servers move with it. Rewriting
	// the file is the whole of the update: the program reads it again itself.
	private void watchNetwork() {
		try {
			ConnectivityManager manager =
				(ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
			if (manager == null) {
				return;
			}
			manager.registerDefaultNetworkCallback(new ConnectivityManager.NetworkCallback() {
				@Override
				public void onAvailable(Network network) {
					writeResolvers();
				}

				@Override
				public void onLost(Network network) {
					writeResolvers();
				}

				@Override
				public void onLinkPropertiesChanged(Network network, LinkProperties properties) {
					writeResolvers();
				}
			});
		} catch (Exception why) {
			Log.w(TAG, "hive: cannot watch the network — " + why);
		}
	}

	@Override
	public void onBackPressed() {
		if (view != null && view.canGoBack()) {
			view.goBack();
			return;
		}
		super.onBackPressed();
	}

	// Closing the window ends the program, the same as it does on a desktop. The
	// runtime no longer ends itself when its socket goes quiet — a sleeping
	// device can hold one quiet for minutes — so this is what stops it.
	@Override
	protected void onDestroy() {
		if (child != null) {
			child.destroy();
			child = null;
		}
		super.onDestroy();
	}
}
